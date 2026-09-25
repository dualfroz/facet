require 'minitest/autorun'
require 'facet'
require 'socket'
require 'timeout'

class WebSocketIntegrationTest < Minitest::Test
  Frame = Facet::WebSocket::Frame
  Handshake = Facet::WebSocket::Handshake

  class EchoChannel
    def self.hub
      @hub ||= Facet::WebSocket::Hub.new
    end

    def on_open(connection)
      self.class.hub.subscribe('echo_room', connection)
      connection.write_text('welcome')
    end

    def on_message(connection, message)
      if message == 'broadcast'
        self.class.hub.broadcast('echo_room', 'broadcasted!')
      else
        connection.write_text("echo: #{message}")
      end
    end

    def on_close(connection)
      self.class.hub.unsubscribe_all(connection)
    end
  end

  class CappedRoomChannel
    def self.hub
      @hub ||= Facet::WebSocket::Hub.new(max_subscribers_per_stream: 1)
    end

    def on_open(connection)
      return connection.close(1008, 'room is full') unless self.class.hub.subscribe('only_room', connection)
      connection.write_text('welcome')
    end

    def on_message(connection, message)
      connection.write_text("echo: #{message}")
    end

    def on_close(connection)
      self.class.hub.unsubscribe_all(connection)
    end
  end

  class WebSocketApp < Facet::Application
    websocket '/cable', EchoChannel
    websocket '/cable-capped', EchoChannel, max_message_size: 16
    websocket '/capped-room', CappedRoomChannel

    get '/ping' do
      html 'pong'
    end
  end

  def setup
    @server = Facet::Server.new(WebSocketApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_ordinary_http_routes_still_work_alongside_a_registered_websocket_path
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    response = socket.read
    socket.close
    assert_includes response, '200'
    assert_includes response, 'pong'
  end

  def test_full_handshake_and_echo_round_trip
    socket = connect_and_upgrade('/cable')

    assert_equal 'welcome', Frame.decode(socket).payload

    socket.write(Frame.encode(Frame::TEXT, 'hello', mask: true))
    assert_equal 'echo: hello', Frame.decode(socket).payload
  ensure
    socket&.close
  end

  def test_unregistered_path_falls_through_to_the_ordinary_app_and_404s
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write(upgrade_request('/no-such-socket'))
    response = read_headers(socket)
    socket.close
    assert_includes response, '404'
  end

  def test_broadcast_reaches_every_subscribed_connection
    a = connect_and_upgrade('/cable')
    b = connect_and_upgrade('/cable')
    assert_equal 'welcome', Frame.decode(a).payload
    assert_equal 'welcome', Frame.decode(b).payload

    a.write(Frame.encode(Frame::TEXT, 'broadcast', mask: true))

    assert_equal 'broadcasted!', Frame.decode(a).payload
    assert_equal 'broadcasted!', Frame.decode(b).payload
  ensure
    a&.close
    b&.close
  end

  def test_close_handshake_is_echoed_back
    socket = connect_and_upgrade('/cable')
    Frame.decode(socket)

    socket.write(Frame.encode(Frame::CLOSE, '', mask: true))
    reply = Frame.decode(socket)
    assert_equal Frame::CLOSE, reply.opcode
  ensure
    socket&.close
  end

  def test_a_per_endpoint_max_message_size_is_enforced_over_the_real_wire
    socket = connect_and_upgrade('/cable-capped')
    Frame.decode(socket)

    socket.write(Frame.encode(Frame::TEXT, 'this payload is well over sixteen bytes', mask: true))
    reply = Frame.decode(socket)
    assert_equal Frame::CLOSE, reply.opcode
    assert_equal 1009, reply.payload.byteslice(0, 2).unpack1('n')
  ensure
    socket&.close
  end

  def test_other_endpoints_keep_the_default_max_message_size
    socket = connect_and_upgrade('/cable')
    Frame.decode(socket)

    socket.write(Frame.encode(Frame::TEXT, 'this payload is well over sixteen bytes', mask: true))
    assert_equal 'echo: this payload is well over sixteen bytes', Frame.decode(socket).payload
  ensure
    socket&.close
  end

  def test_a_hub_subscriber_cap_rejects_the_connection_that_exceeds_it_over_the_real_wire
    first = connect_and_upgrade('/capped-room')
    assert_equal 'welcome', Frame.decode(first).payload

    second = connect_and_upgrade('/capped-room')
    reply = Frame.decode(second)
    assert_equal Frame::CLOSE, reply.opcode
    assert_equal 1008, reply.payload.byteslice(0, 2).unpack1('n')
  ensure
    first&.close
    second&.close
  end

  def test_a_rejected_connection_does_not_disturb_the_one_already_subscribed
    first = connect_and_upgrade('/capped-room')
    Frame.decode(first)

    second = connect_and_upgrade('/capped-room')
    Frame.decode(second)

    first.write(Frame.encode(Frame::TEXT, 'still here', mask: true))
    assert_equal 'echo: still here', Frame.decode(first).payload
  ensure
    first&.close
    second&.close
  end

  def test_closing_the_holder_frees_the_slot_for_the_next_connection
    first = connect_and_upgrade('/capped-room')
    Frame.decode(first)
    first.write(Frame.encode(Frame::CLOSE, '', mask: true))
    Frame.decode(first)
    first.close

    second = connect_and_upgrade('/capped-room')
    assert_equal 'welcome', Frame.decode(second).payload
  ensure
    first&.close
    second&.close
  end

  private

  def upgrade_request(path, key: 'dGhlIHNhbXBsZSBub25jZQ==')
    "GET #{path} HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n" \
      "\r\n"
  end

  def read_headers(socket)
    headers = +''
    until headers.end_with?("\r\n\r\n")
      line = socket.gets("\r\n")
      break if line.nil?
      headers << line
    end
    headers
  end

  def connect_and_upgrade(path)
    socket = TCPSocket.new('127.0.0.1', @port)
    key = 'dGhlIHNhbXBsZSBub25jZQ=='
    socket.write(upgrade_request(path, key: key))
    response = read_headers(socket)
    assert_includes response, '101'
    assert_includes response, Handshake.accept_key(key)
    socket
  end
end

class WebSocketConnectionCapTest < Minitest::Test
  Frame = Facet::WebSocket::Frame
  Handshake = Facet::WebSocket::Handshake

  class EchoChannel
    def on_open(connection)
      connection.write_text('welcome')
    end

    def on_message(connection, message)
      connection.write_text("echo: #{message}")
    end

    def on_close(connection); end
  end

  class WebSocketApp < Facet::Application
    websocket '/cable-a', EchoChannel
    websocket '/cable-b', EchoChannel
  end

  def setup
    @server = Facet::Server.new(WebSocketApp, port: 0, max_websocket_connections: 2).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_connections_within_the_cap_are_accepted_normally
    a = connect_and_upgrade('/cable-a')
    b = connect_and_upgrade('/cable-b')
    assert_equal 'welcome', Frame.decode(a).payload
    assert_equal 'welcome', Frame.decode(b).payload
  ensure
    a&.close
    b&.close
  end

  def test_a_third_connection_across_different_endpoints_is_rejected_with_503
    a = connect_and_upgrade('/cable-a')
    b = connect_and_upgrade('/cable-b')

    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write(upgrade_request('/cable-a'))
    response = read_headers(socket)
    socket.close

    assert_includes response, '503'
    refute_includes response, '101'
  ensure
    a&.close
    b&.close
  end

  def test_closing_a_connection_frees_its_slot_for_a_new_one
    a = connect_and_upgrade('/cable-a')
    b = connect_and_upgrade('/cable-b')
    a.write(Frame.encode(Frame::CLOSE, '', mask: true))
    Frame.decode(a)
    a.close

    Timeout.timeout(2) { sleep 0.01 while @server.websocket_connection_count >= 2 }

    c = connect_and_upgrade('/cable-a')
    assert_equal 'welcome', Frame.decode(c).payload
  ensure
    b&.close
    c&.close
  end

  private

  def upgrade_request(path, key: 'dGhlIHNhbXBsZSBub25jZQ==')
    "GET #{path} HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n" \
      "\r\n"
  end

  def read_headers(socket)
    headers = +''
    until headers.end_with?("\r\n\r\n")
      line = socket.gets("\r\n")
      break if line.nil?
      headers << line
    end
    headers
  end

  def connect_and_upgrade(path)
    socket = TCPSocket.new('127.0.0.1', @port)
    key = 'dGhlIHNhbXBsZSBub25jZQ=='
    socket.write(upgrade_request(path, key: key))
    response = read_headers(socket)
    assert_includes response, '101'
    assert_includes response, Handshake.accept_key(key)
    socket
  end
end
