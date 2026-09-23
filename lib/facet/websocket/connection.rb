module Facet
  module WebSocket
    class Connection
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

      def read_message
        return nil if @closed
        message_opcode = nil
        buffer = String.new(encoding: Encoding::BINARY)

        loop do
          frame = Frame.decode(@socket, max_length: @max_message_size)
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

      def finish(opcode, buffer)
        return buffer unless opcode == Frame::TEXT
        text = buffer.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise ProtocolError.new('text frame payload is not valid UTF-8', code: 1007)
        end
        text
      end

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
