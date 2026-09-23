require 'uri'
require 'stringio'

module Facet
  module Testing
    class IntegrationSession
      attr_reader :response

      def initialize(app)
        @app = app
        @cookies = {}
        @response = nil
      end

      def get(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('GET', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def head(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('HEAD', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def delete(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('DELETE', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def post(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('POST', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def patch(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('PATCH', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def put(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        process('PUT', path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def follow_redirect!
        location = response && response.location
        raise 'no redirect to follow (last response was not a 3xx with a Location header)' unless location

        uri = URI.parse(location)
        target = uri.path.to_s
        target = "#{target}?#{uri.query}" if uri.query
        get(target)
      end

      def cookies
        @cookies.dup
      end

      def clear!
        @cookies = {}
        @response = nil
      end

      private

      QUERY_METHODS = %w[GET HEAD DELETE].freeze

      def process(method, path, params:, headers:, remote_addr:)
        path_part, existing_query = path.to_s.split('?', 2)
        content_type = nil
        body = ''
        query = existing_query

        if params
          if QUERY_METHODS.include?(method)
            encoded = encode_params(params)
            query = [existing_query, encoded].compact.reject(&:empty?).join('&')
          elsif params.is_a?(String)
            body = params
          else
            body = encode_params(params)
            content_type = 'application/x-www-form-urlencoded'
          end
        end

        env = build_env(method, path_part, query, body, headers, content_type, remote_addr)
        status, response_headers, body_parts = @app.call(env)
        @response = TestResponse.new(status, response_headers, body_parts)
        absorb_cookies(@response)
        @response
      end

      def build_env(method, path_part, query, body, headers, content_type, remote_addr)
        env = {
          'REQUEST_METHOD' => method,
          'PATH_INFO' => path_part,
          'QUERY_STRING' => query.to_s,
          'rack.input' => StringIO.new(body || ''),
          'CONTENT_LENGTH' => (body ? body.bytesize.to_s : '0'),
          'REMOTE_ADDR' => remote_addr,
          'SERVER_NAME' => 'test.host',
          'rack.url_scheme' => 'http'
        }
        env['CONTENT_TYPE'] = content_type if content_type

        headers.each do |name, value|
          key = name.to_s
          case key.downcase
          when 'content-type' then env['CONTENT_TYPE'] = value
          when 'content-length' then env['CONTENT_LENGTH'] = value.to_s
          else env["HTTP_#{key.upcase.tr('-', '_')}"] = value
          end
        end

        cookie_header = cookie_header_value
        env['HTTP_COOKIE'] = cookie_header if cookie_header
        env
      end

      def cookie_header_value
        return nil if @cookies.empty?

        @cookies.map { |name, value| "#{name}=#{value}" }.join('; ')
      end

      def absorb_cookies(response)
        response.set_cookies.each { |name, value| @cookies[name] = value }
      end

      def encode_params(params, prefix = nil)
        case params
        when Hash
          params.map { |key, value| encode_params(value, prefix ? "#{prefix}[#{key}]" : key.to_s) }
                .join('&')
        when Array
          params.map { |value| encode_params(value, "#{prefix}[]") }.join('&')
        else
          "#{URI.encode_www_form_component(prefix.to_s)}=#{URI.encode_www_form_component(params.to_s)}"
        end
      end
    end
  end
end
