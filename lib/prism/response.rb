module Prism
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

    # A StreamingBody (or anything else that already knows how to hand
    # itself to a Rack-style server one chunk at a time via #each) is kept
    # as-is rather than wrapped in Array(value) - wrapping it would produce
    # a one-element Array whose element is the streaming object itself,
    # which Server#write_response's ordinary `body.join` path cannot join
    # into a String, and which would defeat the entire point of streaming
    # (nothing would be sent until the whole thing was collected anyway).
    def body=(value)
      @body = value.respond_to?(:each) ? value : Array(value)
    end

    # Sets the body to a StreamingBody wrapping `block`. The block itself
    # does not run yet - only once whatever consumes the finished response
    # (Server#write_response, or a test calling body.each directly) starts
    # pulling chunks, exactly like an ordinary Rack body Array is not
    # "used up" until something calls each/join on it either.
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
