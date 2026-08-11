require 'minitest/autorun'
require 'prism'
require 'net/http'
require 'socket'

class ServerRemoteAddrApp < Prism::Application
  get '/whoami' do
    json(remote_addr: request.env['REMOTE_ADDR'])
  end
end

class ServerTest < Minitest::Test
  def setup
    @server = Prism::Server.new(ServerRemoteAddrApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  # Regression: the hand-rolled Rack env built by Server#read_request never
  # set REMOTE_ADDR, so anything keying off the caller's IP over a real
  # socket - Middleware::RateLimiting's IP-based throttles chief among
  # them - silently never matched, even though the middleware itself was
  # correctly implemented and covered by tests that inject REMOTE_ADDR by
  # hand.
  def test_remote_addr_is_populated_from_the_real_socket
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/whoami"))
    assert_equal '200', response.code
    assert_equal '127.0.0.1', JSON.parse(response.body)['remote_addr']
  end
end

# A controller action returning a Prism::StreamingBody (see
# Prism::Controller#stream) - real end-to-end proof that
# Server#write_chunked_response speaks correct HTTP/1.1 chunked
# Transfer-Encoding over an actual TCPSocket, not just against a directly
# invoked middleware/App#call(env) tuple the way test_controller_streaming.rb
# and test_response.rb both already cover.
class ServerStreamingApp < Prism::Application
  get '/export' do
    headers('Content-Type' => 'text/csv')
    stream do |out|
      out.write("id,title\n")
      out.write("1,one\n")
      out.write("2,two\n")
    end
  end

  get '/plain' do
    json(ok: true)
  end
end

class ServerStreamingTest < Minitest::Test
  def setup
    @server = Prism::Server.new(ServerStreamingApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_net_http_client_receives_the_full_reassembled_body
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/export"))
    assert_equal '200', response.code
    assert_equal "id,title\n1,one\n2,two\n", response.body
  end

  def test_net_http_reports_chunked_transfer_encoding_not_content_length
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/export"))
    assert_equal 'chunked', response['Transfer-Encoding']
    assert_nil response['Content-Length']
  end

  # Reads the raw bytes off the socket ourselves (bypassing Net::HTTP's own
  # chunked-decoding) to prove the wire format itself - not just that some
  # HTTP client happens to be able to reassemble it - matches RFC 7230
  # SS4.1: one `<hex-size>\r\n<data>\r\n` frame per chunk written by the
  # action, in the order it wrote them, followed by the `0\r\n\r\n`
  # terminating chunk.
  def test_raw_wire_bytes_use_correct_chunk_framing
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET /export HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    raw = socket.read
    socket.close

    head, chunked = raw.split("\r\n\r\n", 2)
    assert_includes head, 'Transfer-Encoding: chunked'
    refute_includes head, 'Content-Length'

    expected = "9\r\nid,title\n\r\n" \
               "6\r\n1,one\n\r\n" \
               "6\r\n2,two\n\r\n" \
               "0\r\n\r\n"
    assert_equal expected, chunked
  end

  # A streamed response must not break the keep-alive connection for
  # whatever request comes after it on the same socket - the chunked body
  # is self-delimiting (the 0-length terminating chunk), so Server#serve's
  # normal loop can keep reading the next request right after it exactly
  # like it would after an ordinary Content-Length body.
  def test_keep_alive_connection_survives_a_streamed_response_followed_by_a_plain_one
    Net::HTTP.start('127.0.0.1', @port) do |http|
      first = http.request(Net::HTTP::Get.new('/export'))
      second = http.request(Net::HTTP::Get.new('/plain'))

      assert_equal '200', first.code
      assert_equal "id,title\n1,one\n2,two\n", first.body
      assert_equal '200', second.code
      assert_equal({ 'ok' => true }, JSON.parse(second.body))
    end
  end
end

# A streaming action whose producer block pauses (blocked on a Queue the
# test controls) between two chunks, so a test can yank the client socket
# out from under it mid-stream at a precise, non-racy point instead of
# guessing with a sleep.
class ServerAbandonedStreamApp < Prism::Application
  class << self
    attr_accessor :gate
  end

  get '/slow-export' do
    stream do |out|
      out.write("first\n")
      self.class.gate.pop
      out.write("second\n")
    end
  end

  get '/plain' do
    json(ok: true)
  end
end

# Regression coverage for the "not a dedicated test" gap left open by the
# streaming session (see prism-postep.md, sesja 91, "NIE zweryfikowane"):
# write_chunked_response's `socket.write` runs against a socket the client
# may have already closed, and Server#serve wraps the WHOLE request loop in
# `rescue Errno::EPIPE, Errno::ECONNRESET, IOError` to survive that - but
# nothing had ever actually exercised a real abandoned connection mid-chunk.
class ServerAbandonedStreamTest < Minitest::Test
  def setup
    ServerAbandonedStreamApp.gate = Queue.new
    @server = Prism::Server.new(ServerAbandonedStreamApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_client_disconnecting_mid_stream_does_not_crash_the_server_or_wedge_future_requests
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET /slow-export HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")

    # Wait for the first chunk to actually land on the wire before pulling
    # the rug - otherwise we might close before write_chunked_response's
    # loop has even started, proving nothing about a write to a dead socket.
    ready = IO.select([socket], nil, nil, 2)
    refute_nil ready, 'server never sent the first chunk within 2s'
    socket.recv(4096)
    socket.close
    sleep 0.05 # let the kernel actually deliver the FIN/RST before we continue the producer

    ServerAbandonedStreamApp.gate.push(:go)
    sleep 0.1 # give the (separate) serve() thread a moment to hit the dead write and rescue it

    # The real assertion: whatever happened to that abandoned write, the
    # server process itself is still alive and still accepting brand-new
    # connections on a fresh socket - Server#serve's rescue clause did its
    # job instead of an unhandled exception silently killing the accept
    # loop or leaving the process in a broken state.
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/plain"))
    assert_equal '200', response.code
    assert_equal({ 'ok' => true }, JSON.parse(response.body))
  end
end
