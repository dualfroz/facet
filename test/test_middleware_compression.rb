require 'minitest/autorun'
require 'prism'
require 'support'
require 'zlib'
require 'stringio'

class MiddlewareCompressionTest < Minitest::Test
  include TestSupport

  LARGE_BODY = 'x' * 1000

  def gunzip(bytes)
    Zlib::GzipReader.new(StringIO.new(bytes)).read
  end

  def app_returning(status, headers, body)
    Prism::Middleware::Compression.new(lambda { |_env| [status, headers, body] })
  end

  def test_compresses_a_large_buffered_body_when_client_accepts_gzip
    app = app_returning(200, {'Content-Type' => 'text/html'}, [LARGE_BODY])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => 'gzip'})
    status, headers, body = app.call(env)

    assert_equal 200, status
    assert_equal 'gzip', headers['Content-Encoding']
    assert_equal LARGE_BODY, gunzip(body.join)
    assert_equal body.join.bytesize.to_s, headers['Content-Length']
  end

  def test_leaves_the_body_alone_when_the_client_sends_no_accept_encoding
    app = app_returning(200, {'Content-Type' => 'text/html'}, [LARGE_BODY])
    status, headers, body = app.call(env_for('GET', '/posts'))

    assert_equal 200, status
    assert_nil headers['Content-Encoding']
    assert_equal LARGE_BODY, body.join
  end

  def test_respects_an_explicit_gzip_q0_declining_the_encoding
    app = app_returning(200, {'Content-Type' => 'text/html'}, [LARGE_BODY])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => 'gzip;q=0, *;q=1'})
    _, headers, body = app.call(env)

    assert_nil headers['Content-Encoding']
    assert_equal LARGE_BODY, body.join
  end

  def test_a_wildcard_accept_encoding_is_honored
    app = app_returning(200, {'Content-Type' => 'text/html'}, [LARGE_BODY])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => '*'})
    _, headers, body = app.call(env)

    assert_equal 'gzip', headers['Content-Encoding']
    assert_equal LARGE_BODY, gunzip(body.join)
  end

  def test_skips_bodies_smaller_than_the_threshold
    app = app_returning(200, {'Content-Type' => 'text/html'}, ['tiny'])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => 'gzip'})
    _, headers, body = app.call(env)

    assert_nil headers['Content-Encoding']
    assert_equal 'tiny', body.join
  end

  def test_skips_a_response_that_already_carries_a_content_encoding
    headers = {'Content-Type' => 'text/html', 'Content-Encoding' => 'br'}
    app = app_returning(200, headers, [LARGE_BODY])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => 'gzip'})
    _, out_headers, body = app.call(env)

    assert_equal 'br', out_headers['Content-Encoding']
    assert_equal LARGE_BODY, body.join
  end

  def test_skips_media_content_types
    app = app_returning(200, {'Content-Type' => 'image/png'}, [LARGE_BODY])
    env = env_for('GET', '/logo.png', headers: {'Accept-Encoding' => 'gzip'})
    _, headers, body = app.call(env)

    assert_nil headers['Content-Encoding']
    assert_equal LARGE_BODY, body.join
  end

  def test_skips_a_partial_content_range_response
    headers = {'Content-Type' => 'text/plain', 'Content-Range' => 'bytes 0-99/1000'}
    app = app_returning(206, headers, [LARGE_BODY[0, 100]])
    env = env_for('GET', '/file', headers: {'Accept-Encoding' => 'gzip'})
    status, out_headers, = app.call(env)

    assert_equal 206, status
    assert_nil out_headers['Content-Encoding']
  end

  def test_skips_a_304_not_modified_response
    app = app_returning(304, {}, [])
    env = env_for('GET', '/file', headers: {'Accept-Encoding' => 'gzip'})
    status, headers, = app.call(env)

    assert_equal 304, status
    assert_nil headers['Content-Encoding']
  end

  def test_skips_head_requests
    app = app_returning(200, {'Content-Type' => 'text/html'}, [LARGE_BODY])
    env = env_for('HEAD', '/posts', headers: {'Accept-Encoding' => 'gzip'})
    _, headers, body = app.call(env)

    assert_nil headers['Content-Encoding']
    assert_equal LARGE_BODY, body.join
  end

  def test_appends_to_an_existing_vary_header_instead_of_replacing_it
    app = app_returning(200, {'Content-Type' => 'text/html', 'Vary' => 'Accept'}, [LARGE_BODY])
    env = env_for('GET', '/posts', headers: {'Accept-Encoding' => 'gzip'})
    _, headers, = app.call(env)

    assert_equal 'Accept, Accept-Encoding', headers['Vary']
  end

  def test_streams_a_streaming_body_as_a_single_gzip_stream_chunk_by_chunk
    written_before_producer_returns = nil
    downstream = lambda do |_env|
      body = Prism::StreamingBody.new do |writer|
        writer.write("id,title\n")
        writer.write("1,one\n")
        writer.write("2,two\n")
      end
      [200, {'Content-Type' => 'text/csv'}, body]
    end
    app = Prism::Middleware::Compression.new(downstream)
    env = env_for('GET', '/posts/export', headers: {'Accept-Encoding' => 'gzip'})
    status, headers, body = app.call(env)

    assert_equal 200, status
    assert_equal 'gzip', headers['Content-Encoding']
    assert_nil headers['Content-Length']
    assert_kind_of Prism::StreamingBody, body

    chunks = []
    body.each { |chunk| chunks << chunk }
    assert chunks.size > 1, 'expected more than one gzip chunk (one per producer write)'
    assert_equal "id,title\n1,one\n2,two\n", gunzip(chunks.join)
  end

  def test_a_second_each_on_the_wrapped_streaming_body_reruns_the_producer_with_a_fresh_gzip_stream
    downstream = lambda do |_env|
      body = Prism::StreamingBody.new { |writer| writer.write('hello world') }
      [200, {'Content-Type' => 'text/plain'}, body]
    end
    app = Prism::Middleware::Compression.new(downstream)
    env = env_for('GET', '/x', headers: {'Accept-Encoding' => 'gzip'})
    _, _, body = app.call(env)

    first = +''
    body.each { |chunk| first << chunk }
    second = +''
    body.each { |chunk| second << chunk }

    assert_equal 'hello world', gunzip(first)
    assert_equal 'hello world', gunzip(second)
  end
end
