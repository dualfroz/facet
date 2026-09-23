module Facet
  class Response
    attr_accessor :status
    attr_reader :headers, :body

    def initialize(status: 200, headers: nil, body: nil)
      @status = status
      @headers = headers || { 'Content-Type' => 'text/html;charset=utf-8' }
      @body = body ? Array(body) : []
    end

    def write(chunk)
      @body << chunk.to_s
      self
    end
    alias_method :<<, :write

    def [](name)
      @headers[name]
    end

    def []=(name, value)
      @headers[name] = value
    end

    def body=(value)
      @body = value.respond_to?(:each) ? value : Array(value)
    end

    def stream(&block)
      self.body = StreamingBody.new(&block)
      self
    end

    def streaming?
      @body.is_a?(StreamingBody)
    end

    def set_cookie(name, value, options = {})
      cookie = +"#{name}=#{CGI.escape(value.to_s)}"
      cookie << "; Path=#{options[:path] || '/'}"
      cookie << "; Max-Age=#{options[:max_age]}" if options[:max_age]
      cookie << '; HttpOnly' if options.fetch(:http_only, true)
      cookie << '; Secure' if options[:secure]
      cookie << "; SameSite=#{options[:same_site]}" if options[:same_site]
      existing = @headers['Set-Cookie']
      @headers['Set-Cookie'] = existing ? "#{existing}\n#{cookie}" : cookie
    end

    def finish
      [@status, @headers, @body]
    end
  end
end
