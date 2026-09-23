module Facet
  module WebSocket
    module Handshake
      GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

      module_function

      def request?(env)
        env['REQUEST_METHOD'] == 'GET' &&
          env['HTTP_UPGRADE'].to_s.downcase == 'websocket' &&
          env['HTTP_CONNECTION'].to_s.downcase.split(/,\s*/).include?('upgrade') &&
          !env['HTTP_SEC_WEBSOCKET_KEY'].to_s.empty?
      end

      def accept_key(client_key)
        [Digest::SHA1.digest(client_key + GUID)].pack('m0')
      end

      def response_headers(env)
        {
          'Upgrade' => 'websocket',
          'Connection' => 'Upgrade',
          'Sec-WebSocket-Accept' => accept_key(env.fetch('HTTP_SEC_WEBSOCKET_KEY'))
        }
      end
    end
  end
end
