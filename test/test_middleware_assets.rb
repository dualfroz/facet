require 'minitest/autorun'
require 'prism'
require 'support'
require 'tmpdir'
require 'fileutils'

class MiddlewareAssetsTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('prism-assets-mw')
    @downstream_calls = 0
    downstream = lambda do |_env|
      @downstream_calls += 1
      [404, {}, ['not found downstream']]
    end
    @app = Prism::Middleware::Assets.new(downstream, root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_fingerprinted(name, content)
    File.write(File.join(@dir, name), content)
  end

  def test_serves_a_fingerprinted_file_with_far_future_cache_control
    write_fingerprinted('application-deadbeef.css', 'body{color:red}')

    status, headers, body = @app.call(env_for('GET', '/assets/application-deadbeef.css'))

    assert_equal 200, status
    assert_equal 'body{color:red}', body.first
    assert_equal 'text/css', headers['Content-Type']
    assert_equal 'public, max-age=31536000, immutable', headers['Cache-Control']
  end

  def test_does_not_cache_forever_a_file_without_a_fingerprint
    write_fingerprinted('manifest.json', '{}')

    _status, headers, = @app.call(env_for('GET', '/assets/manifest.json'))

    refute headers.key?('Cache-Control')
  end

  def test_passes_through_to_downstream_app_for_paths_outside_the_prefix
    status, = @app.call(env_for('GET', '/posts'))

    assert_equal 404, status
    assert_equal 1, @downstream_calls
  end

  def test_passes_through_to_downstream_app_when_the_file_is_missing
    status, = @app.call(env_for('GET', '/assets/does-not-exist.css'))

    assert_equal 404, status
    assert_equal 1, @downstream_calls
  end

  def test_rejects_path_traversal_outside_the_root
    write_fingerprinted('secret.txt', 'nope')
    outside = File.join(File.dirname(@dir), 'outside.txt')
    File.write(outside, 'top secret')

    status, = @app.call(env_for('GET', "/assets/../#{File.basename(outside)}"))

    assert_equal 404, status
    assert_equal 1, @downstream_calls
  ensure
    FileUtils.rm_f(outside)
  end

  def test_custom_prefix
    app = Prism::Middleware::Assets.new(->(_env) { [404, {}, []] }, root: @dir, prefix: '/static')
    write_fingerprinted('app-11111111.js', 'console.log(1)')

    status, = app.call(env_for('GET', '/static/app-11111111.js'))

    assert_equal 200, status
  end

  def test_serves_a_byte_range_as_206_with_content_range
    write_fingerprinted('video-cafebabe.bin', '0123456789')

    status, headers, body = @app.call(env_for('GET', '/assets/video-cafebabe.bin', headers: { 'Range' => 'bytes=2-5' }))

    assert_equal 206, status
    assert_equal '2345', body.first
    assert_equal 'bytes 2-5/10', headers['Content-Range']
    assert_equal '4', headers['Content-Length']
    assert_equal 'public, max-age=31536000, immutable', headers['Cache-Control']
  end

  def test_unsatisfiable_range_is_416_with_no_body
    write_fingerprinted('video-cafebabe.bin', '0123456789')

    status, headers, body = @app.call(env_for('GET', '/assets/video-cafebabe.bin', headers: { 'Range' => 'bytes=100-200' }))

    assert_equal 416, status
    assert_equal 'bytes */10', headers['Content-Range']
    assert_equal [], body
  end

  def test_head_request_with_range_has_no_body_but_keeps_headers
    write_fingerprinted('video-cafebabe.bin', '0123456789')

    status, headers, body = @app.call(env_for('HEAD', '/assets/video-cafebabe.bin', headers: { 'Range' => 'bytes=0-3' }))

    assert_equal 206, status
    assert_equal [], body
    assert_equal 'bytes 0-3/10', headers['Content-Range']
    assert_equal '4', headers['Content-Length']
  end

  def test_fingerprinted_file_gets_a_strong_hash_derived_etag
    write_fingerprinted('application-deadbeef.css', 'body{color:red}')

    _status, headers, = @app.call(env_for('GET', '/assets/application-deadbeef.css'))

    assert_equal '"deadbeef"', headers['ETag']
  end

  def test_non_fingerprinted_file_gets_a_weak_etag
    write_fingerprinted('manifest.json', '{}')

    _status, headers, = @app.call(env_for('GET', '/assets/manifest.json'))

    assert_match(/\AW\/"\d+-\d+"\z/, headers['ETag'])
  end

  def test_if_none_match_against_fingerprint_etag_returns_304
    write_fingerprinted('application-deadbeef.css', 'body{color:red}')

    status, headers, body = @app.call(env_for('GET', '/assets/application-deadbeef.css', headers: { 'If-None-Match' => '"deadbeef"' }))

    assert_equal 304, status
    assert_equal [], body
    assert_equal '"deadbeef"', headers['ETag']
  end

  def test_if_range_by_strong_fingerprint_etag_honors_the_range
    write_fingerprinted('video-cafebabe.bin', '0123456789')

    status, headers, body = @app.call(env_for('GET', '/assets/video-cafebabe.bin', headers: { 'Range' => 'bytes=0-3', 'If-Range' => '"cafebabe"' }))

    assert_equal 206, status
    assert_equal '0123', body.first
    assert_equal 'bytes 0-3/10', headers['Content-Range']
  end

  def test_if_range_by_mismatched_fingerprint_etag_falls_back_to_full_200
    write_fingerprinted('video-cafebabe.bin', '0123456789')

    status, _, body = @app.call(env_for('GET', '/assets/video-cafebabe.bin', headers: { 'Range' => 'bytes=0-3', 'If-Range' => '"stale0000"' }))

    assert_equal 200, status
    assert_equal '0123456789', body.first
  end
end
