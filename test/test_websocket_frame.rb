require 'minitest/autorun'
require 'facet'
require 'stringio'

class WebSocketFrameTest < Minitest::Test
  Frame = Facet::WebSocket::Frame

  def decode(bytes)
    Frame.decode(StringIO.new(bytes))
  end

  def test_encodes_and_decodes_a_short_unmasked_text_frame
    encoded = Frame.encode(Frame::TEXT, 'hi')
    frame = decode(encoded)
    assert frame.fin
    assert_equal Frame::TEXT, frame.opcode
    assert_equal 'hi', frame.payload
  end

  def test_masked_frame_round_trips_the_same_payload_as_unmasked
    encoded = Frame.encode(Frame::TEXT, 'client says hi', mask: true)
    frame = decode(encoded)
    assert_equal 'client says hi', frame.payload
    unmasked = Frame.encode(Frame::TEXT, 'client says hi')
    refute_equal unmasked, encoded
  end

  def test_two_masked_encodes_of_the_same_payload_differ_by_mask_key
    first = Frame.encode(Frame::TEXT, 'same payload', mask: true)
    second = Frame.encode(Frame::TEXT, 'same payload', mask: true)
    refute_equal first, second
    assert_equal decode(first).payload, decode(second).payload
  end

  def test_medium_payload_uses_the_16_bit_length_field
    payload = 'x' * 200
    encoded = Frame.encode(Frame::BINARY, payload)
    assert_equal 126, encoded.getbyte(1) & 0x7F
    assert_equal payload, decode(encoded).payload
  end

  def test_large_payload_uses_the_64_bit_length_field
    payload = 'x' * 70_000
    encoded = Frame.encode(Frame::BINARY, payload)
    assert_equal 127, encoded.getbyte(1) & 0x7F
    assert_equal 70_000, decode(encoded).payload.bytesize
  end

  def test_fin_bit_is_clear_on_a_fragment
    encoded = Frame.encode(Frame::TEXT, 'part one', fin: false)
    frame = decode(encoded)
    refute frame.fin
  end

  def test_close_ping_pong_opcodes_round_trip
    [Frame::CLOSE, Frame::PING, Frame::PONG].each do |opcode|
      frame = decode(Frame.encode(opcode, 'payload'))
      assert_equal opcode, frame.opcode
      assert_equal 'payload', frame.payload
    end
  end

  def test_decode_raises_protocol_error_when_stream_ends_mid_frame
    encoded = Frame.encode(Frame::TEXT, 'truncated me')
    truncated = encoded[0...-3]
    assert_raises(Facet::WebSocket::ProtocolError) { decode(truncated) }
  end

  def test_empty_payload_round_trips
    frame = decode(Frame.encode(Frame::PING, ''))
    assert_equal '', frame.payload
  end

  def test_decode_reports_whether_the_frame_was_masked
    refute decode(Frame.encode(Frame::TEXT, 'x')).masked
    assert decode(Frame.encode(Frame::TEXT, 'x', mask: true)).masked
  end

  def test_decode_accepts_a_frame_within_the_max_length
    frame = Frame.decode(StringIO.new(Frame.encode(Frame::TEXT, 'ok')), max_length: 10)
    assert_equal 'ok', frame.payload
  end

  def test_decode_rejects_an_oversized_frame_before_reading_its_payload
    header = ((0x80 | Frame::BINARY)).chr + 127.chr + [10_000_000].pack('Q>')
    io = StringIO.new(header)
    error = assert_raises(Facet::WebSocket::ProtocolError) { Frame.decode(io, max_length: 1024) }
    assert_match(/exceeds the 1024 byte limit/, error.message)
    assert_equal 1009, error.code
  end

  def test_protocol_error_defaults_to_the_generic_1002_close_code
    error = assert_raises(Facet::WebSocket::ProtocolError) { decode('') }
    assert_equal 1002, error.code
  end
end
