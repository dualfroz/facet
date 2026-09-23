require 'monitor'

module Facet
  module WebSocket
    class Hub
      include MonitorMixin

      def initialize(max_subscribers_per_stream: nil)
        super()
        @streams = Hash.new { |hash, key| hash[key] = [] }
        @max_subscribers_per_stream = max_subscribers_per_stream
      end

      def subscribe(stream, connection)
        synchronize do
          list = @streams[stream]
          next true if list.any? { |existing| existing.equal?(connection) }
          next false if @max_subscribers_per_stream && list.size >= @max_subscribers_per_stream

          list << connection
          true
        end
      end

      def unsubscribe(stream, connection)
        synchronize do
          @streams[stream].reject! { |existing| existing.equal?(connection) }
          @streams.delete(stream) if @streams.key?(stream) && @streams[stream].empty?
        end
      end

      def unsubscribe_all(connection)
        synchronize do
          @streams.each_value { |connections| connections.reject! { |existing| existing.equal?(connection) } }
          @streams.reject! { |_stream, connections| connections.empty? }
        end
      end

      def subscribers(stream)
        synchronize { @streams[stream].dup }
      end

      def broadcast(stream, data)
        payload = data.is_a?(String) ? data : JSON.generate(data)
        subscribers(stream).each do |connection|
          connection.write_text(payload)
          unsubscribe(stream, connection) if connection.closed?
        end
      end
    end
  end
end
