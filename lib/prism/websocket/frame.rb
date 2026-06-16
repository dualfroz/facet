module Prism
  module WebSocket
    # `code` is the RFC 6455 section 7.4.1 close status code the caller
    # should echo back to the peer before dropping the connection (1002
    # generic protocol error by default, 1009 for the message/frame-too-big
    # cases below, 1007 for invalid UTF-8 in a TEXT message payload -
    # callers other than Connection#read_message are free to ignore it).
    class ProtocolError < StandardError
      attr_reader :code

      def initialize(message = nil, code: 1002)
        super(message)
        @code = code
      end
    end

    # RFC 6455 section 5.2 frame codec - encode/decode a single WebSocket
    # frame. Server->client frames are sent unmasked; client->server frames
    # arrive masked and must be unmasked before use (both directions are
    # exercised by Connection and by the tests, since this file has no
    # opinion on which side it is running as).
    module Frame
      CONTINUATION = 0x0
      TEXT = 0x1
      BINARY = 0x2
      CLOSE = 0x8
      PING = 0x9
      PONG = 0xA

      Decoded = Struct.new(:fin, :opcode, :payload, :masked, keyword_init: true)

      module_function

      def encode(opcode, payload, fin: true, mask: false)
        payload = payload.to_s.dup.force_encoding(Encoding::BINARY)
        length = payload.bytesize
        mask_bit = mask ? 0x80 : 0x00

        header = String.new(encoding: Encoding::BINARY)
        header << (((fin ? 0x80 : 0x00) | (opcode & 0x0F))).chr
        if length <= 125
          header << (mask_bit | length).chr
        elsif length <= 0xFFFF
          header << (mask_bit | 126).chr << [length].pack('n')
        else
          header << (mask_bit | 127).chr << [length].pack('Q>')
        end

        return header + payload unless mask

        mask_key = Random.bytes(4)
        header << mask_key << apply_mask(payload, mask_key)
      end

      # Blocks on `io` (anything responding to #read) until one full frame
      # (header, optional mask key, payload) has arrived. `max_length`, when
      # given, rejects an oversized length field before it is ever used to
      # read from `io` - without it a peer only has to send a truthful
      # 64-bit length header (no need to actually deliver that many bytes
      # for this check alone) to make the caller block forever/allocate an
      # unbounded buffer.
      def decode(io, max_length: nil)
        first, second = read_exact(io, 2).unpack('C2')
        fin = (first & 0x80) != 0
        opcode = first & 0x0F
        masked = (second & 0x80) != 0
        length = second & 0x7F

        length = read_exact(io, 2).unpack1('n') if length == 126
        length = read_exact(io, 8).unpack1('Q>') if length == 127

        if max_length && length > max_length
          raise ProtocolError.new("frame payload of #{length} bytes exceeds the #{max_length} byte limit", code: 1009)
        end

        mask_key = read_exact(io, 4) if masked
        payload = read_exact(io, length)
        payload = apply_mask(payload, mask_key) if masked

        Decoded.new(fin: fin, opcode: opcode, payload: payload, masked: masked)
      end

      def apply_mask(payload, mask_key)
        masked = payload.dup.force_encoding(Encoding::BINARY)
        length = masked.bytesize
        index = 0
        while index < length
          masked.setbyte(index, masked.getbyte(index) ^ mask_key.getbyte(index % 4))
          index += 1
        end
        masked
      end

      def read_exact(io, count)
        return String.new(encoding: Encoding::BINARY) if count.zero?
        data = io.read(count)
        raise ProtocolError, 'connection closed mid-frame' if data.nil? || data.bytesize != count
        data
      end
    end
  end
end
