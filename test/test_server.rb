require 'minitest/autorun'
require 'facet'
require 'net/http'
require 'socket'

class ServerRemoteAddrApp < Facet::Application
  get '/whoami' do
    json(remote_addr: request.env['REMOTE_ADDR'])
  end
end

class ServerTest < Minitest::Test
  def setup
    @server = Facet::Server.new(ServerRemoteAddrApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_remote_addr_is_populated_from_the_real_socket
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/whoami"))
    assert_equal '200', response.code
    assert_equal '127.0.0.1', JSON.parse(response.body)['remote_addr']
  end
end

class ServerStreamingApp < Facet::Application
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
    @server = Facet::Server.new(ServerStreamingApp, port: 0).start
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

class ServerAbandonedStreamApp < Facet::Application
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

class ServerAbandonedStreamTest < Minitest::Test
  def setup
    ServerAbandonedStreamApp.gate = Queue.new
    @server = Facet::Server.new(ServerAbandonedStreamApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_client_disconnecting_mid_stream_does_not_crash_the_server_or_wedge_future_requests
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET /slow-export HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")

    ready = IO.select([socket], nil, nil, 2)
    refute_nil ready, 'server never sent the first chunk within 2s'
    socket.recv(4096)
    socket.close
    sleep 0.05

    ServerAbandonedStreamApp.gate.push(:go)
    sleep 0.1

    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/plain"))
    assert_equal '200', response.code
    assert_equal({ 'ok' => true }, JSON.parse(response.body))
  end
end
