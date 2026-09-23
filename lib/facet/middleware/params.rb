module Facet
  module Middleware
    class ParamsParser
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Request.new(env)
        body = request.body
        rewind(env)

        if json_body?(request, body) && !valid_json?(body)
          return bad_request
        end

        @app.call(env)
      end

      private

      def rewind(env)
        input = env['rack.input']
        input.rewind if input.respond_to?(:rewind)
      end

      def json_body?(request, body)
        request.content_type.to_s.include?('application/json') && !body.empty?
      end

      def valid_json?(body)
        JSON.parse(body)
        true
      rescue JSON::ParserError
        false
      end

      def bad_request
        payload = JSON.generate(error: 'invalid JSON body')
        [400, { 'Content-Type' => 'application/json' }, [payload]]
      end
    end
  end
end
