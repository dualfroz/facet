require 'monitor'

module Prism
  module WebSocket
    # ActionCable-lite pub/sub broadcaster: application handlers subscribe
    # a Connection to one or more named streams (e.g. "chat_room_3"), and
    # any thread can broadcast to that stream without knowing who, or how
    # many connections, are listening. Guarded by a Monitor the same way
    # RateLimiter::MemoryStore is, since broadcasts and subscribe/unsubscribe
    # routinely come from different threads at once (one per connection).
    class Hub
      include MonitorMixin

      # max_subscribers_per_stream is a hard cap on how many connections may
      # share one stream name at once - unbounded fan-in on a single stream
      # (e.g. every visitor to one wildly popular post) is a real resource
      # exhaustion path (one broadcast call fans out to an unbounded number
      # of live sockets) that nothing upstream of Hub was guarding against.
      # nil (the default) keeps the old unbounded behavior.
      def initialize(max_subscribers_per_stream: nil)
        super()
        @streams = Hash.new { |hash, key| hash[key] = [] }
        @max_subscribers_per_stream = max_subscribers_per_stream
      end

      # Membership is checked/removed by object identity (`equal?`), not
      # `==`/`eql?` - a Connection is "the same subscriber" only if it is
      # literally the same object, regardless of whether whatever class
      # wraps a socket happens to define value equality.
      #
      # Returns true if the connection is (now, or already was) subscribed,
      # false if the stream is at max_subscribers_per_stream and this is a
      # genuinely new subscriber - callers (channel handlers) are expected
      # to close the connection (e.g. with code 1008, policy violation) when
      # they get false back, the same way they already do for a missing/
      # invalid stream key.
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

      # Sends `data` to every connection currently subscribed to `stream`.
      # A Hash/Array payload is JSON-encoded (the common case - structured
      # events), a String is sent verbatim. A connection whose socket has
      # already died is dropped from the stream instead of raising, so one
      # dead client can never break delivery to the rest.
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
