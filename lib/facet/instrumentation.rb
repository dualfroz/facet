module Facet
  module Instrumentation
    Event = Struct.new(:name, :payload, :duration, :time) do
      def duration_ms
        duration * 1000.0
      end
    end

    class Subscriber
      def initialize(pattern, block)
        @pattern = pattern
        @block = block
      end

      def match?(name)
        case @pattern
        when nil then true
        when Regexp then @pattern.match?(name)
        else @pattern.to_s == name
        end
      end

      def call(event)
        @block.call(event)
      end
    end

    class Bus
      def initialize
        @subscribers = []
        @mutex = Mutex.new
      end

      def subscribe(pattern = nil, &block)
        raise ArgumentError, 'block required' unless block
        subscriber = Subscriber.new(pattern, block)
        @mutex.synchronize { @subscribers = @subscribers + [subscriber] }
        subscriber
      end

      def unsubscribe(subscriber)
        @mutex.synchronize { @subscribers = @subscribers - [subscriber] }
      end

      def subscribers
        @mutex.synchronize { @subscribers.dup }
      end

      def instrument(name, payload = {})
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        time = Time.now
        result = nil
        begin
          result = block_given? ? yield(payload) : nil
          result
        rescue StandardError => e
          payload[:exception] = [e.class.name, e.message]
          payload[:exception_object] = e
          raise
        ensure
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          publish(Event.new(name, payload, duration, time))
        end
      end

      private

      def publish(event)
        subscribers.each do |subscriber|
          next unless subscriber.match?(event.name)
          subscriber.call(event)
        end
      end
    end

    class << self
      def bus
        @bus ||= Bus.new
      end

      def instrument(name, payload = {}, &block)
        bus.instrument(name, payload, &block)
      end

      def subscribe(pattern = nil, &block)
        bus.subscribe(pattern, &block)
      end

      def unsubscribe(subscriber)
        bus.unsubscribe(subscriber)
      end
    end

    class LogSubscriber
      def self.attach(io = $stdout, patterns: [nil])
        patterns.map do |pattern|
          Instrumentation.subscribe(pattern) { |event| io.puts(format_event(event)) }
        end
      end

      def self.format_event(event)
        ms = format('%.1f', event.duration_ms)
        details = event.payload.reject { |key, _| key == :exception_object }
                        .map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
        line = "  #{event.name} (#{ms}ms)"
        details.empty? ? line : "#{line}  #{details}"
      end
    end
  end
end
