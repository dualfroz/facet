module Prism
  module Middleware
    # Handles the CORS preflight (OPTIONS with Access-Control-Request-Method)
    # and stamps Access-Control-* response headers on matching simple/actual
    # requests, per the whatwg fetch spec's precedence: no Origin header means
    # this is not a cross-origin request at all, so it passes through untouched.
    class Cors
      def initialize(app, registry: Prism::Cors)
        @app = app
        @registry = registry
      end

      def call(env)
        origin = env['HTTP_ORIGIN']
        return @app.call(env) unless origin

        match = @registry.resource_for(origin, format_agnostic_path(env['PATH_INFO']))
        return @app.call(env) unless match
        _rule, resource = match

        if preflight?(env)
          preflight_response(env, origin, resource)
        else
          status, headers, body = @app.call(env)
          [status, apply_headers(headers, origin, resource), body]
        end
      end

      private

      # Cors resources are registered against logical route paths
      # ('/posts'), but PATH_INFO still carries an optional trailing
      # ".json"/".xml" format extension at this point in the stack (the
      # router only strips it internally while matching) - without this,
      # a resource registered for '/posts' would never match '/posts.json'.
      def format_agnostic_path(path)
        path.sub(%r{\.[^./]+\z}, '')
      end

      def preflight?(env)
        env['REQUEST_METHOD'] == 'OPTIONS' && !env['HTTP_ACCESS_CONTROL_REQUEST_METHOD'].to_s.empty?
      end

      def preflight_response(env, origin, resource)
        requested_method = env['HTTP_ACCESS_CONTROL_REQUEST_METHOD']
        requested_headers = env['HTTP_ACCESS_CONTROL_REQUEST_HEADERS']

        unless resource.allows_method?(requested_method) && resource.allows_headers?(requested_headers)
          return [403, {}, ['CORS preflight rejected']]
        end

        headers = apply_headers({}, origin, resource)
        headers['Access-Control-Allow-Methods'] = resource.methods.join(', ')
        unless requested_headers.to_s.empty?
          headers['Access-Control-Allow-Headers'] = requested_headers
        end
        headers['Access-Control-Max-Age'] = resource.max_age.to_s if resource.max_age
        [204, headers, []]
      end

      def apply_headers(headers, origin, resource)
        headers['Access-Control-Allow-Origin'] = origin
        headers['Access-Control-Allow-Credentials'] = 'true' if resource.credentials
        headers['Access-Control-Expose-Headers'] = resource.expose.join(', ') unless resource.expose.empty?
        headers['Vary'] = append_vary(headers['Vary'], 'Origin')
        headers
      end

      def append_vary(existing, value)
        return value if existing.to_s.empty?
        existing.split(',').map(&:strip).push(value).uniq.join(', ')
      end
    end
  end
end
