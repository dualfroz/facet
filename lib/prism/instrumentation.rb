module Prism
  # ActiveSupport::Notifications-lite: a process-wide publish/subscribe bus
  # for cross-cutting events (queries, request dispatch, template renders).
  # Instrumented code owns naming and payload shape; subscribers (loggers,
  # metrics collectors, tests) opt into a subset by exact name or Regexp.
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

      # Yields a mutable payload hash so instrumented code (and nested
      # instrument calls further down the stack) can enrich it before the
      # event is published. Always publishes, even when the block raises -
      # the exception is recorded on the payload and re-raised afterward.
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

    # Rails-style one-line-per-event logger: "  sql.prism (0.3ms)  SELECT posts".
    # Attach once (typically in an initializer / Application setup); returns
    # the underlying Subscriber so callers can #detach it later.
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
