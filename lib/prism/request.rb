module Prism
  class Request
    attr_reader :env

    def initialize(env)
      @env = env
    end

    OverridableMethods = %w[PUT PATCH DELETE].freeze

    def request_method
      @request_method ||= compute_request_method
    end

    def path
      @env['PATH_INFO']
    end

    def query_string
      @env['QUERY_STRING'].to_s
    end

    def content_type
      @env['CONTENT_TYPE']
    end

    def user_agent
      @env['HTTP_USER_AGENT']
    end

    def remote_addr
      @env['REMOTE_ADDR']
    end

    def body
      @body ||= begin
        input = @env['rack.input']
        content = input ? input.read : ''
        input.rewind if input.respond_to?(:rewind)
        content
      end
    end

    def headers
      @headers ||= @env.each_with_object({}) do |(key, value), acc|
        next unless key.start_with?('HTTP_')
        name = key[5..].split('_').map(&:capitalize).join('-')
        acc[name] = value
      end
    end

    def query_params
      @query_params ||= parse_query(query_string)
    end

    def body_params
      @body_params ||= parse_body
    end

    def cookies
      @cookies ||= parse_cookies(@env['HTTP_COOKIE'])
    end

    def path_params
      @path_params ||= {}
    end

    def path_params=(value)
      @path_params = value
      @params = nil
    end

    def params
      @params ||= begin
        merged = Params.from(body_params)
        query_params.each { |key, value| merged[key] = value }
        path_params.each { |key, value| merged[key] = value }
        merged
      end
    end

    # Negotiated response format: an explicit `.json` path/query extension
    # wins, otherwise it falls back to the Accept header, defaulting to
    # :html when nothing else matches (mirrors Rails' request.format).
    def format
      explicit = path_params['format'] || query_params['format']
      return explicit.to_s.to_sym unless explicit.nil? || explicit.to_s.empty?
      Mime.best_from_accept(headers['Accept']) || :html
    end

    private

    def compute_request_method
      actual = @env['REQUEST_METHOD']
      return actual unless actual == 'POST'
      override = (@env['HTTP_X_HTTP_METHOD_OVERRIDE'] || body_params['_method']).to_s.upcase
      OverridableMethods.include?(override) ? override : actual
    end

    def parse_query(string)
      return Params.new if string.empty?
      Params.nested_from(URI.decode_www_form(string))
    rescue ArgumentError
      Params.new
    end

    def parse_body
      return Params.new if body.empty?
      if content_type&.include?('application/json')
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? Params.from(parsed) : Params.from('_json' => parsed)
      elsif content_type&.include?('application/x-www-form-urlencoded')
        Params.nested_from(URI.decode_www_form(body))
      elsif Multipart.multipart?(content_type)
        Multipart.parse(body, Multipart.boundary_from(content_type))
      else
        Params.new
      end
    rescue JSON::ParserError, ArgumentError
      Params.new
    end

    def parse_cookies(header)
      return {} if header.nil? || header.empty?
      header.split(/;\s*/).each_with_object({}) do |pair, acc|
        name, value = pair.split('=', 2)
        acc[name] = value.nil? ? '' : CGI.unescape(value)
      end
    end
  end
end
