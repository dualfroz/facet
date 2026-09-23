require 'monitor'

module Facet
  module RateLimiter
    class MemoryStore
      include MonitorMixin

      Window = Struct.new(:started_at, :count)

      def initialize
        super()
        @windows = {}
        @bans = {}
      end

      def count(key, period)
        synchronize do
          now = Time.now
          window = @windows[key]
          if window.nil? || now - window.started_at >= period
            window = Window.new(now, 0)
            @windows[key] = window
          end
          window.count += 1
        end
      end

      def banned?(key)
        synchronize do
          expires_at = @bans[key]
          next false unless expires_at
          if Time.now >= expires_at
            @bans.delete(key)
            false
          else
            true
          end
        end
      end

      def ban!(key, duration)
        synchronize { @bans[key] = Time.now + duration }
      end

      def reset!
        synchronize do
          @windows.clear
          @bans.clear
        end
      end
    end
  end
end
