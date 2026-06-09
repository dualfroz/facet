require_relative 'rate_limiter/memory_store'
require_relative 'rate_limiter/pstore_store'

module Prism
  # Rack::Attack-lite: request throttling, blocklisting/safelisting and a
  # fail2ban-style repeat-offender ban, evaluated by
  # Middleware::RateLimiting on every request. Rules are discriminator
  # blocks that receive a Prism::Request and return a truthy key (or nil
  # to skip the rule for that request) - the same shape for all four rule
  # kinds, only how the key is used differs.
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

      # Bans +discriminator+ (typically an IP) for +bantime+ seconds once
      # the block yields true +maxretry+ times within a +findtime+ window -
      # the classic fail2ban pattern, e.g. banning an IP that repeatedly
      # probes for `/etc/passwd` in the query string. Meant to be called
      # from inside a #blocklist block.
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
