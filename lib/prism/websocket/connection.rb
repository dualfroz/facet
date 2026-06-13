module Prism
  module WebSocket
    # Wraps a raw socket that has already completed the opening handshake.
    # Handles the framing-level protocol on its own (ping->pong, message
    # fragmentation reassembly, close handshake) so application handlers
    # only ever see whole text/binary messages via #read_message.
    class Connection
      # RFC 6455 sets no upper bound on frame/message size - a raw length
      # field can claim up to 2**64 bytes. Left unchecked, a single
      # malicious or buggy peer can force an unbounded buffer allocation
      # (or an effectively infinite fragmented message) per connection.
      # 16 MiB comfortably covers any real chat/notification/live-update
      # payload this framework's Hub is meant to broadcast.
      DEFAULT_MAX_MESSAGE_SIZE = 16 * 1024 * 1024

      attr_reader :env

      def initialize(socket, env: {}, max_message_size: DEFAULT_MAX_MESSAGE_SIZE)
        @socket = socket
        @env = env
        @closed = false
        @max_message_size = max_message_size
      end

      def closed?
        @closed
      end

      # Blocks until one complete (possibly reassembled from several
      # fragments) text/binary message arrives, or returns nil once the
      # peer has closed the connection (after echoing the close frame back,
      # per RFC 6455 section 5.5.1).
      def read_message
        return nil if @closed
        message_opcode = nil
        buffer = String.new(encoding: Encoding::BINARY)

        loop do
          frame = Frame.decode(@socket, max_length: @max_message_size)
          # RFC 6455 section 5.1: "the server MUST close the connection
          # upon receiving a frame that is not masked" - a Connection is
          # always the server's view of a single client, so every frame it
          # reads must be masked regardless of opcode.
          raise ProtocolError, 'received an unmasked frame from the client' unless frame.masked

          case frame.opcode
          when Frame::PING
            write_frame(Frame::PONG, frame.payload)
          when Frame::PONG
            nil
          when Frame::CLOSE
            write_frame(Frame::CLOSE, frame.payload)
            @closed = true
            return nil
          when Frame::CONTINUATION
            raise ProtocolError, 'continuation frame without a preceding data frame' if message_opcode.nil?
            buffer << frame.payload
            check_message_size!(buffer)
            return finish(message_opcode, buffer) if frame.fin
          else
            unless message_opcode.nil?
              raise ProtocolError, 'new data frame received before previous fragmented message finished'
            end
            return finish(frame.opcode, frame.payload) if frame.fin
            message_opcode = frame.opcode
            buffer << frame.payload
            check_message_size!(buffer)
          end
        end
      rescue ProtocolError => e
        # RFC 6455 section 7.1.5/7.4: a server that is about to drop the
        # connection because of a protocol violation SHOULD still send a
        # Close frame carrying the reason, rather than just vanishing -
        # best-effort (the peer, or the TCP connection itself, may already
        # be gone, in which case #close's own write_frame swallows the
        # resulting EPIPE/IOError same as everywhere else in this class).
        close(e.code, e.message.to_s.byteslice(0, 123).to_s)
        @closed = true
        raise
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @closed = true
        nil
      end

      def write_text(text)
        write_frame(Frame::TEXT, text)
      end

      def write_binary(bytes)
        write_frame(Frame::BINARY, bytes)
      end

      def close(code = 1000, reason = '')
        return if @closed
        write_frame(Frame::CLOSE, [code].pack('n') + reason)
        @closed = true
      end

      private

      # RFC 6455 section 8.1: "When an endpoint is to interpret a byte
      # stream as UTF-8 but finds that the byte stream is not, in fact, a
      # valid UTF-8 stream, that endpoint MUST _Fail the WebSocket
      # Connection_" - checked on the fully reassembled message, not per
      # fragment, since a multi-byte UTF-8 character can legally be split
      # across a CONTINUATION boundary and only becomes checkable once
      # whole again.
      def finish(opcode, buffer)
        return buffer unless opcode == Frame::TEXT
        text = buffer.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise ProtocolError.new('text frame payload is not valid UTF-8', code: 1007)
        end
        text
      end

      # A message reassembled from many small fragments can exceed
      # @max_message_size even though each individual frame passed
      # Frame.decode's per-frame check - checked again after every
      # fragment is appended, not just once at the end.
      def check_message_size!(buffer)
        return unless buffer.bytesize > @max_message_size
        raise ProtocolError.new(
          "reassembled message of #{buffer.bytesize} bytes exceeds the #{@max_message_size} byte limit",
          code: 1009
        )
      end

      def write_frame(opcode, payload)
        @socket.write(Frame.encode(opcode, payload))
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @closed = true
      end
    end
  end
end
