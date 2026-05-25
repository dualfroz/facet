module Prism
  module Renderable
    def params
      @request.params
    end

    def session
      @env['prism.session'] ||= Params.new
    end

    def flash
      @flash ||= Flash.new(session)
    end

    def cookies
      @request.cookies
    end

    def status(code = nil)
      @response.status = code if code
      @response.status
    end

    def headers(hash = nil)
      @response.headers.merge!(hash) if hash
      @response.headers
    end

    def json(object, code = nil)
      @response.status = code if code
      @response['Content-Type'] = 'application/json'
      payload = JSON.generate(object)
      @response.body = [payload]
      payload
    end

    def html(markup, code = nil)
      @response.status = code if code
      @response['Content-Type'] = 'text/html;charset=utf-8'
      @response.body = [markup]
      markup
    end

    def redirect(location, code = 302)
      @response.status = code
      @response['Location'] = location
      @response.body = []
      halt
    end

    def halt(code = nil, body = nil)
      @response.status = code if code
      case body
      when String then @response.body = [body]
      when Array then @response.body = body
      end
      throw :halt
    end

    def pass
      throw :pass
    end

    def set_cookie(name, value, options = {})
      @response.set_cookie(name, value, options)
    end

    def url_for(name, params = {})
      router = @env['prism.router'] || raise('no router available for url_for')
      router.path_to(name, params)
    end

    def finalize_flash
      @flash.sweep if @flash
    end
  end
end
