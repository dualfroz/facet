require 'minitest/autorun'
require 'facet'
require 'socket'

class WebSocketConnectionTest < Minitest::Test
  Frame = Facet::WebSocket::Frame

  def setup
    @server_socket, @client_socket = Socket.pair(:UNIX, :STREAM, 0)
    @connection = Facet::WebSocket::Connection.new(@server_socket)
  end

  def teardown
    @server_socket.close unless @server_socket.closed?
    @client_socket.close unless @client_socket.closed?
  end

  def test_reads_a_single_unfragmented_text_message
    @client_socket.write(Frame.encode(Frame::TEXT, 'hello', mask: true))
    assert_equal 'hello', @connection.read_message
  end

  def test_reassembles_a_fragmented_message_across_continuation_frames
    @client_socket.write(Frame.encode(Frame::TEXT, 'foo', fin: false, mask: true))
    @client_socket.write(Frame.encode(Frame::CONTINUATION, 'bar', fin: false, mask: true))
    @client_socket.write(Frame.encode(Frame::CONTINUATION, 'baz', mask: true))
    assert_equal 'foobarbaz', @connection.read_message
  end

  def test_automatically_replies_to_a_ping_with_a_pong_and_keeps_reading
    @client_socket.write(Frame.encode(Frame::PING, 'are you there', mask: true))
    @client_socket.write(Frame.encode(Frame::TEXT, 'after the ping', mask: true))

    assert_equal 'after the ping', @connection.read_message

    reply = Frame.decode(@client_socket)
    assert_equal Frame::PONG, reply.opcode
    assert_equal 'are you there', reply.payload
  end

  def test_close_frame_echoes_close_and_returns_nil
    @client_socket.write(Frame.encode(Frame::CLOSE, '', mask: true))
    assert_nil @connection.read_message
    assert @connection.closed?

    reply = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, reply.opcode
  end

  def test_write_text_is_visible_on_the_other_end_unmasked
    @connection.write_text('pushed from the server')
    frame = Frame.decode(@client_socket)
    assert_equal Frame::TEXT, frame.opcode
    assert_equal 'pushed from the server', frame.payload
  end

  def test_continuation_without_a_preceding_data_frame_raises
    @client_socket.write(Frame.encode(Frame::CONTINUATION, 'orphan', mask: true))
    assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_read_message_returns_nil_once_closed
    @connection.close
    assert_nil @connection.read_message
  end

  def test_raises_on_an_unmasked_data_frame_from_the_client
    @client_socket.write(Frame.encode(Frame::TEXT, 'no mask', mask: false))
    assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_raises_on_an_unmasked_control_frame_from_the_client
    @client_socket.write(Frame.encode(Frame::PING, 'no mask', mask: false))
    assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_raises_when_a_single_frame_exceeds_the_configured_max_message_size
    capped = Facet::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 20, mask: true))
    assert_raises(Facet::WebSocket::ProtocolError) { capped.read_message }
    assert capped.closed?
  end

  def test_raises_when_fragments_reassemble_past_the_configured_max_message_size
    capped = Facet::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 8, fin: false, mask: true))
    @client_socket.write(Frame.encode(Frame::CONTINUATION, 'x' * 8, mask: true))
    assert_raises(Facet::WebSocket::ProtocolError) { capped.read_message }
    assert capped.closed?
  end

  def test_protocol_violation_sends_a_1002_close_frame_to_the_client_before_raising
    @client_socket.write(Frame.encode(Frame::TEXT, 'no mask', mask: false))
    error = assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }
    assert_equal 1002, error.code

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1002, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  def test_oversized_message_sends_a_1009_close_frame_to_the_client_before_raising
    capped = Facet::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 20, mask: true))
    error = assert_raises(Facet::WebSocket::ProtocolError) { capped.read_message }
    assert_equal 1009, error.code

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1009, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  def test_raises_1007_on_invalid_utf8_text_payload
    invalid = String.new("\xC3\x28", encoding: Encoding::BINARY)
    @client_socket.write(Frame.encode(Frame::TEXT, invalid, mask: true))
    error = assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }
    assert_equal 1007, error.code
    assert @connection.closed?
  end

  def test_invalid_utf8_sends_a_1007_close_frame_to_the_client_before_raising
    invalid = String.new("\xC3\x28", encoding: Encoding::BINARY)
    @client_socket.write(Frame.encode(Frame::TEXT, invalid, mask: true))
    assert_raises(Facet::WebSocket::ProtocolError) { @connection.read_message }

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1007, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  def test_valid_utf8_split_across_a_continuation_boundary_is_accepted
    first_byte = String.new("\xC3", encoding: Encoding::BINARY)
    second_byte = String.new("\xA9", encoding: Encoding::BINARY)
    @client_socket.write(Frame.encode(Frame::TEXT, first_byte, fin: false, mask: true))
    @client_socket.write(Frame.encode(Frame::CONTINUATION, second_byte, mask: true))

    message = @connection.read_message
    assert_equal "\u00e9", message
    assert message.valid_encoding?
  end
end
