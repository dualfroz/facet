require_relative 'rate_limiter/memory_store'
require_relative 'rate_limiter/pstore_store'

module Facet
  module RateLimiter
    class Rule
      attr_reader :name, :limit, :period

      def initialize(name:, discriminator:, limit: nil, period: nil)
        @name = name
        @discriminator = discriminator
        @limit = limit
        @period = period
      end

      def key_for(request)
        @discriminator.call(request)
      end
    end

    class << self
      attr_writer :store

      def store
        @store ||= MemoryStore.new
      end

      def throttles
        @throttles ||= {}
      end

      def blocklists
        @blocklists ||= {}
      end

      def safelists
        @safelists ||= {}
      end

      def tracks
        @tracks ||= {}
      end

      def throttle(name, limit:, period:, &discriminator)
        throttles[name.to_s] = Rule.new(name: name.to_s, discriminator: discriminator, limit: limit, period: period)
      end

      def blocklist(name, &discriminator)
        blocklists[name.to_s] = Rule.new(name: name.to_s, discriminator: discriminator)
      end

      def safelist(name, &discriminator)
        safelists[name.to_s] = Rule.new(name: name.to_s, discriminator: discriminator)
      end

      def track(name, &discriminator)
        tracks[name.to_s] = Rule.new(name: name.to_s, discriminator: discriminator)
      end

      def on_notify(&block)
        @notifier = block
      end

      def notify(type, name, request, payload = nil)
        @notifier&.call(type, name, request, payload)
      end

      def fail2ban_filter(discriminator, maxretry:, findtime:, bantime:)
        key = "fail2ban:#{discriminator}"
        return true if store.banned?(key)
        return false unless yield
        count = store.count(key, findtime)
        return false if count < maxretry
        store.ban!(key, bantime)
        true
      end

      def reset!
        @throttles = {}
        @blocklists = {}
        @safelists = {}
        @tracks = {}
        @notifier = nil
        store.reset!
      end
    end
  end
end
