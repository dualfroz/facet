require 'pstore'
require 'fileutils'

module Facet
  module RateLimiter
    class PStoreStore
      def initialize(path)
        @path = path
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless directory == '.' || Dir.exist?(directory)
        @pstore = PStore.new(path)
        @pstore.transaction do
          @pstore[:windows] ||= {}
          @pstore[:bans] ||= {}
        end
      end

      def count(key, period)
        @pstore.transaction do
          now = Time.now
          started_at, current = @pstore[:windows][key]
          if started_at.nil? || now - started_at >= period
            started_at = now
            current = 0
          end
          current += 1
          @pstore[:windows][key] = [started_at, current]
          current
        end
      end

      def banned?(key)
        @pstore.transaction do
          expires_at = @pstore[:bans][key]
          if expires_at.nil?
            false
          elsif Time.now >= expires_at
            @pstore[:bans].delete(key)
            false
          else
            true
          end
        end
      end

      def ban!(key, duration)
        @pstore.transaction { @pstore[:bans][key] = Time.now + duration }
      end

      def reset!
        @pstore.transaction do
          @pstore[:windows] = {}
          @pstore[:bans] = {}
        end
      end
    end
  end
end
