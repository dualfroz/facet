module Facet
  module Cache
    class Entry
      def initialize(value, expires_at)
        @value = value
        @expires_at = expires_at
      end

      attr_reader :value

      def expired?(now)
        @expires_at && now >= @expires_at
      end
    end

    class MemoryStore
      def initialize(max_size: nil)
        @data = {}
        @mutex = Mutex.new
        @max_size = max_size
      end

      def read(key)
        @mutex.synchronize { read_locked(key.to_s) }
      end

      def write(key, value, expires_in: nil)
        expires_at = expires_in ? monotonic_now + expires_in : nil
        key = key.to_s
        @mutex.synchronize do
          @data.delete(key)
          @data[key] = Entry.new(value, expires_at)
          evict_excess
        end
        value
      end

      def fetch(key, expires_in: nil)
        existing = read(key)
        return existing unless existing.nil?
        value = yield
        write(key, value, expires_in: expires_in)
        value
      end

      def delete(key)
        @mutex.synchronize { !@data.delete(key.to_s).nil? }
      end

      def delete_matched(pattern)
        regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern.to_s).gsub('\*', '.*'))
        @mutex.synchronize { @data.reject! { |key, _| key =~ regex } }
      end

      def exist?(key)
        !read(key).nil?
      end

      def clear
        @mutex.synchronize { @data.clear }
      end

      def size
        @mutex.synchronize { @data.size }
      end

      private

      def read_locked(key)
        entry = @data[key]
        return nil unless entry
        if entry.expired?(monotonic_now)
          @data.delete(key)
          return nil
        end
        @data.delete(key)
        @data[key] = entry
        entry.value
      end

      def evict_excess
        return unless @max_size
        @data.shift while @data.size > @max_size
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class << self
      def store
        @store ||= MemoryStore.new
      end

      attr_writer :store
    end
  end
end
