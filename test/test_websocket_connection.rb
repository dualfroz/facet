require 'minitest/autorun'
require 'prism'
require 'socket'

# Exercises Connection over a real connected socket pair (one end plays the
# framework's Connection, the other plays a raw client sending hand-built
# frames) rather than mocking the socket, since the interesting behavior
# here - auto ping/pong, fragment reassembly, the close handshake - is all
# about how bytes actually flow across the wire.
class WebSocketConnectionTest < Minitest::Test
  Frame = Prism::WebSocket::Frame

  def setup
    @server_socket, @client_socket = Socket.pair(:UNIX, :STREAM, 0)
    @connection = Prism::WebSocket::Connection.new(@server_socket)
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
    assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_read_message_returns_nil_once_closed
    @connection.close
    assert_nil @connection.read_message
  end

  # RFC 6455 5.1: the server MUST close the connection upon receiving a
  # frame that is not masked - a Connection is always the server's view
  # of one client, so this applies to every opcode, not just data frames.
  def test_raises_on_an_unmasked_data_frame_from_the_client
    @client_socket.write(Frame.encode(Frame::TEXT, 'no mask', mask: false))
    assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_raises_on_an_unmasked_control_frame_from_the_client
    @client_socket.write(Frame.encode(Frame::PING, 'no mask', mask: false))
    assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }
    assert @connection.closed?
  end

  def test_raises_when_a_single_frame_exceeds_the_configured_max_message_size
    capped = Prism::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 20, mask: true))
    assert_raises(Prism::WebSocket::ProtocolError) { capped.read_message }
    assert capped.closed?
  end

  # Each individual fragment fits under the cap, but the reassembled
  # message does not - proves the check runs on the accumulated buffer,
  # not only on Frame.decode's per-frame length.
  def test_raises_when_fragments_reassemble_past_the_configured_max_message_size
    capped = Prism::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 8, fin: false, mask: true))
    @client_socket.write(Frame.encode(Frame::CONTINUATION, 'x' * 8, mask: true))
    assert_raises(Prism::WebSocket::ProtocolError) { capped.read_message }
    assert capped.closed?
  end

  # RFC 6455 7.4.1: 1002 is the generic "protocol error" close status.
  def test_protocol_violation_sends_a_1002_close_frame_to_the_client_before_raising
    @client_socket.write(Frame.encode(Frame::TEXT, 'no mask', mask: false))
    error = assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }
    assert_equal 1002, error.code

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1002, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  # RFC 6455 7.4.1: 1009 is the "message too big" close status - distinct
  # from the generic 1002 raised by the other ProtocolError cases above.
  def test_oversized_message_sends_a_1009_close_frame_to_the_client_before_raising
    capped = Prism::WebSocket::Connection.new(@server_socket, max_message_size: 10)
    @client_socket.write(Frame.encode(Frame::TEXT, 'x' * 20, mask: true))
    error = assert_raises(Prism::WebSocket::ProtocolError) { capped.read_message }
    assert_equal 1009, error.code

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1009, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  # RFC 6455 8.1: a TEXT frame payload that is not valid UTF-8 must fail
  # the connection - "\xC3\x28" is a textbook invalid 2-byte sequence
  # (0xC3 wants a continuation byte in 0x80..0xBF next, 0x28 is not one).
  def test_raises_1007_on_invalid_utf8_text_payload
    invalid = String.new("\xC3\x28", encoding: Encoding::BINARY)
    @client_socket.write(Frame.encode(Frame::TEXT, invalid, mask: true))
    error = assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }
    assert_equal 1007, error.code
    assert @connection.closed?
  end

  # RFC 6455 7.4.1: 1007 is the "invalid payload data" close status -
  # distinct from 1002/1009 raised by the other ProtocolError cases above.
  def test_invalid_utf8_sends_a_1007_close_frame_to_the_client_before_raising
    invalid = String.new("\xC3\x28", encoding: Encoding::BINARY)
    @client_socket.write(Frame.encode(Frame::TEXT, invalid, mask: true))
    assert_raises(Prism::WebSocket::ProtocolError) { @connection.read_message }

    close_frame = Frame.decode(@client_socket)
    assert_equal Frame::CLOSE, close_frame.opcode
    assert_equal 1007, close_frame.payload.byteslice(0, 2).unpack1('n')
  end

  # A legally split multi-byte character (the 2-byte UTF-8 encoding of
  # "e" with an acute accent, split after its first byte across a
  # CONTINUATION boundary) must NOT be rejected - proves validation runs
  # on the fully reassembled message, not per fragment.
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
