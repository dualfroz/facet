module Prism
  class Request
    attr_reader :env

    def initialize(env)
      @env = env
    end

    def request_method
      @env['REQUEST_METHOD']
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

    def body
      @body ||= begin
        input = @env['rack.input']
        input ? input.read : ''
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

    private

    def parse_query(string)
      return Params.new if string.empty?
      Params.from(URI.decode_www_form(string).to_h)
    rescue ArgumentError
      Params.new
    end

    def parse_body
      return Params.new if body.empty?
      if content_type&.include?('application/json')
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? Params.from(parsed) : Params.from('_json' => parsed)
      elsif content_type&.include?('application/x-www-form-urlencoded')
        Params.from(URI.decode_www_form(body).to_h)
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
