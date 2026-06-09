module Prism
  module Middleware
    # Evaluates Prism::RateLimiter rules on every request, in the same
    # precedence order as Rack::Attack: safelist bypasses everything,
    # then blocklist (403), then throttles (429 with Retry-After), then
    # tracks (observation only, request still proceeds).
    class RateLimiting
      def initialize(app, limiter: Prism::RateLimiter)
        @app = app
        @limiter = limiter
      end

      def call(env)
        request = Request.new(env)
        return @app.call(env) if safelisted?(request)
        return respond(403, 'Forbidden') if blocked?(request)

        rule = throttled(request)
        return respond(429, 'Too Many Requests', 'Retry-After' => rule.period.to_s) if rule

        track(request)
        @app.call(env)
      end

      private

      def safelisted?(request)
        @limiter.safelists.each_value.any? { |rule| rule.key_for(request) }
      end

      def blocked?(request)
        @limiter.blocklists.each_value.any? { |rule| rule.key_for(request) }
      end

      def throttled(request)
        @limiter.throttles.each_value do |rule|
          key = rule.key_for(request)
          next unless key
          count = @limiter.store.count("#{rule.name}:#{key}", rule.period)
          next unless count > rule.limit
          @limiter.notify(:throttle, rule.name, request, key)
          return rule
        end
        nil
      end

      def track(request)
        @limiter.tracks.each_value do |rule|
          value = rule.key_for(request)
          @limiter.notify(:track, rule.name, request, value) if value
        end
      end

      def respond(status, message, extra_headers = {})
        [status, { 'Content-Type' => 'text/plain' }.merge(extra_headers), [message]]
      end
    end
  end
end
