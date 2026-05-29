require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class MiddlewareStaticTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('prism-static-root')
    File.write(File.join(@root, 'index.html'), '<h1>static</h1>')
    FileUtils.mkdir_p(File.join(@root, 'css'))
    File.write(File.join(@root, 'css', 'app.css'), 'body { color: red; }')
    @downstream = ->(env) { [404, {}, ["app: #{env['PATH_INFO']}"]] }
    @app = Prism::Middleware::Static.new(@downstream, root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def env_for(path, method: 'GET')
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
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
end
