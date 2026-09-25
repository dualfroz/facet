require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class MiddlewareStaticTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('facet-static-root')
    File.write(File.join(@root, 'index.html'), '<h1>static</h1>')
    FileUtils.mkdir_p(File.join(@root, 'css'))
    File.write(File.join(@root, 'css', 'app.css'), 'body { color: red; }')
    @downstream = ->(env) { [404, {}, ["app: #{env['PATH_INFO']}"]] }
    @app = Facet::Middleware::Static.new(@downstream, root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def env_for(path, method: 'GET', range: nil)
    env = { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
    env['HTTP_RANGE'] = range if range
    env
  end

  def test_serves_existing_file
    status, headers, body = @app.call(env_for('/index.html'))
    assert_equal 200, status
    assert_equal 'text/html;charset=utf-8', headers['Content-Type']
    assert_equal '<h1>static</h1>', body.join
  end

  def test_serves_nested_file_with_correct_content_type
    status, headers, body = @app.call(env_for('/css/app.css'))
    assert_equal 200, status
    assert_equal 'text/css', headers['Content-Type']
    assert_equal 'body { color: red; }', body.join
  end

  def test_falls_through_to_app_when_file_missing
    status, _, body = @app.call(env_for('/nope.html'))
    assert_equal 404, status
    assert_equal 'app: /nope.html', body.join
  end

  def test_blocks_path_traversal_outside_root
    status, _, body = @app.call(env_for('/../../../../etc/passwd'))
    assert_equal 404, status
    assert_equal 'app: /../../../../etc/passwd', body.join
  end

  def test_serves_directory_index_when_requesting_a_folder
    FileUtils.mkdir_p(File.join(@root, 'docs'))
    File.write(File.join(@root, 'docs', 'index.html'), '<h1>docs home</h1>')
    status, headers, body = @app.call(env_for('/docs'))
    assert_equal 200, status
    assert_equal 'text/html;charset=utf-8', headers['Content-Type']
    assert_equal '<h1>docs home</h1>', body.join
  end

  def test_falls_through_when_directory_has_no_index_file
    FileUtils.mkdir_p(File.join(@root, 'empty-dir'))
    status, _, body = @app.call(env_for('/empty-dir'))
    assert_equal 404, status
    assert_equal 'app: /empty-dir', body.join
  end

  def test_ignores_non_get_head_requests
    status, _, body = @app.call(env_for('/index.html', method: 'POST'))
    assert_equal 404, status
    assert_equal 'app: /index.html', body.join
  end

  def test_full_response_advertises_accept_ranges
    status, headers, = @app.call(env_for('/index.html'))
    assert_equal 200, status
    assert_equal 'bytes', headers['Accept-Ranges']
  end

  def test_serves_a_byte_range_as_206
    File.write(File.join(@root, 'data.bin'), '0123456789')

    status, headers, body = @app.call(env_for('/data.bin', range: 'bytes=0-3'))

    assert_equal 206, status
    assert_equal '0123', body.join
    assert_equal 'bytes 0-3/10', headers['Content-Range']
    assert_equal '4', headers['Content-Length']
  end

  def test_serves_a_suffix_range
    File.write(File.join(@root, 'data.bin'), '0123456789')

    status, headers, body = @app.call(env_for('/data.bin', range: 'bytes=-3'))

    assert_equal 206, status
    assert_equal '789', body.join
    assert_equal 'bytes 7-9/10', headers['Content-Range']
  end

  def test_unsatisfiable_range_returns_416
    File.write(File.join(@root, 'data.bin'), '0123456789')

    status, headers, body = @app.call(env_for('/data.bin', range: 'bytes=50-60'))

    assert_equal 416, status
    assert_equal 'bytes */10', headers['Content-Range']
    assert_equal [], body
  end

  def test_multi_range_request_falls_back_to_full_200
    File.write(File.join(@root, 'data.bin'), '0123456789')

    status, _, body = @app.call(env_for('/data.bin', range: 'bytes=0-1,3-4'))

    assert_equal 200, status
    assert_equal '0123456789', body.join
  end

  def test_head_request_omits_body_but_reports_full_length
    status, headers, body = @app.call(env_for('/index.html', method: 'HEAD'))

    assert_equal 200, status
    assert_equal [], body
    assert_equal '<h1>static</h1>'.bytesize.to_s, headers['Content-Length']
  end

  def test_full_response_carries_etag_and_last_modified
    _status, headers, = @app.call(env_for('/index.html'))

    assert_match(/\AW\/"\d+-\d+"\z/, headers['ETag'])
    refute_nil headers['Last-Modified']
  end

  def env_with_header(path, name, value, method: 'GET')
    env = env_for(path, method: method)
    env[name] = value
    env
  end

  def test_if_none_match_matching_etag_returns_304_without_body
    _status, headers, = @app.call(env_for('/index.html'))
    etag = headers['ETag']

    status, headers_304, body = @app.call(env_with_header('/index.html', 'HTTP_IF_NONE_MATCH', etag))

    assert_equal 304, status
    assert_equal [], body
    assert_equal etag, headers_304['ETag']
    assert_nil headers_304['Content-Type']
    assert_nil headers_304['Content-Length']
  end

  def test_if_none_match_stale_etag_returns_full_200
    status, headers, body = @app.call(env_with_header('/index.html', 'HTTP_IF_NONE_MATCH', '"stale"'))

    assert_equal 200, status
    assert_equal '<h1>static</h1>', body.join
    refute_nil headers['ETag']
  end

  def test_if_modified_since_in_the_future_returns_304
    status, _, body = @app.call(env_with_header('/index.html', 'HTTP_IF_MODIFIED_SINCE', (Time.now + 3600).utc.httpdate))

    assert_equal 304, status
    assert_equal [], body
  end

  def test_if_modified_since_in_the_past_returns_full_200
    status, _, body = @app.call(env_with_header('/index.html', 'HTTP_IF_MODIFIED_SINCE', Time.at(0).utc.httpdate))

    assert_equal 200, status
    assert_equal '<h1>static</h1>', body.join
  end

  def test_if_range_with_weak_etag_never_satisfies_so_range_is_ignored
    File.write(File.join(@root, 'data.bin'), '0123456789')
    _status, headers, = @app.call(env_for('/data.bin'))
    weak_etag = headers['ETag']

    env = env_with_header('/data.bin', 'HTTP_IF_RANGE', weak_etag)
    env['HTTP_RANGE'] = 'bytes=0-3'
    status, _, body = @app.call(env)

    assert_equal 200, status
    assert_equal '0123456789', body.join
  end

  def test_if_range_with_stale_date_falls_back_to_full_200
    File.write(File.join(@root, 'data.bin'), '0123456789')

    env = env_with_header('/data.bin', 'HTTP_IF_RANGE', Time.at(0).utc.httpdate)
    env['HTTP_RANGE'] = 'bytes=0-3'
    status, _, body = @app.call(env)

    assert_equal 200, status
    assert_equal '0123456789', body.join
  end

  def test_if_range_with_exact_matching_date_honors_the_range
    File.write(File.join(@root, 'data.bin'), '0123456789')
    _status, headers, = @app.call(env_for('/data.bin'))
    last_modified = headers['Last-Modified']

    env = env_with_header('/data.bin', 'HTTP_IF_RANGE', last_modified)
    env['HTTP_RANGE'] = 'bytes=0-3'
    status, headers_206, body = @app.call(env)

    assert_equal 206, status
    assert_equal '0123', body.join
    assert_equal 'bytes 0-3/10', headers_206['Content-Range']
  end
end
