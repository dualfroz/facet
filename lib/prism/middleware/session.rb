module Prism
  module Middleware
    class Session
      CookieName = 'prism.session'.freeze

      def initialize(app, secret:, previous_secrets: [], cookie_name: CookieName, **options)
        @app = app
        @secret = secret
        @previous_secrets = previous_secrets
        @cookie_name = cookie_name
        @options = options
      end

      def call(env)
        request = Request.new(env)
        loaded = Prism::Session.decode(request.cookies[@cookie_name], @secret, previous_secrets: @previous_secrets)
        session = Params.from(loaded)
        env['prism.session'] = session
        env['prism.secret'] = @secret
        env['prism.previous_secrets'] = @previous_secrets
        original = session.dup

        status, headers, body = @app.call(env)

        current = env['prism.session']
        if current != original
          write_cookie(headers, Prism::Session.encode(current.to_h, @secret))
        end
        [status, headers, body]
      end

      private

      def write_cookie(headers, value)
        pieces = ["#{@cookie_name}=#{value}", 'Path=/', 'HttpOnly', 'SameSite=Lax']
        pieces << "Max-Age=#{@options[:max_age]}" if @options[:max_age]
        line = pieces.join('; ')
        existing = headers['Set-Cookie']
        headers['Set-Cookie'] = existing ? "#{existing}\n#{line}" : line
      end
    end
  end
end
