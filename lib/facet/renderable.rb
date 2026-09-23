module Facet
  module Renderable
    def params
      @request.params
    end

    def session
      @env['facet.session'] ||= Params.new
    end

    def flash
      @flash ||= Flash.new(session)
    end

    def cookies
      @cookie_jar ||= begin
        secret = @env['facet.secret']
        if secret
          CookieJar.new(@request, @response, secret: secret, previous_secrets: @env['facet.previous_secrets'] || [])
        else
          @request.cookies
        end
      end
    end

    def csrf
      @csrf ||= Csrf.new(session)
    end

    def csrf_token
      csrf.masked_token
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

    def render_errors(record, status: 422)
      json({ errors: record.errors.to_jsonapi(status: status) }, status)
    end

    def render_not_found(detail, status: 404)
      json({ errors: [{ status: status.to_s, title: 'Resource Not Found', detail: detail }] }, status)
    end

    def html(markup, code = nil)
      @response.status = code if code
      @response['Content-Type'] = 'text/html;charset=utf-8'
      @response.body = [markup]
      markup
    end

    def stream(&block)
      @response.stream(&block)
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
      router = @env['facet.router'] || raise('no router available for url_for')
      router.path_to(name, params)
    end

    def finalize_flash
      @flash.sweep if @flash
    end

    def locale
      @locale ||= detect_locale
    end

    def translate(key, **options)
      Facet::I18n.t(key, locale: options.delete(:locale) || locale, **options)
    end
    alias_method :t, :translate

    def localize(value, **options)
      Facet::I18n.l(value, locale: options.delete(:locale) || locale, **options)
    end
    alias_method :l, :localize

    private

    def detect_locale
      requested = params['locale'] || session[:locale]
      return requested.to_sym if requested && available_locale?(requested)

      negotiated = Facet::I18n.best_locale_from_accept(@request.headers['Accept-Language'])
      negotiated || Facet::I18n.default_locale
    end

    def available_locale?(candidate)
      Facet::I18n.available_locales.map(&:to_s).include?(candidate.to_s)
    end
  end
end
