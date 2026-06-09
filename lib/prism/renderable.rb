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
      @cookie_jar ||= begin
        secret = @env['prism.secret']
        if secret
          CookieJar.new(@request, @response, secret: secret, previous_secrets: @env['prism.previous_secrets'] || [])
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

    # JSON:API-lite error response for a failed-validation record: `{
    # "errors": [...] }` with each entry built by Orm::Errors#to_jsonapi.
    # Mirrors `render_errors(post)` -> `format.json` the same way `render`
    # covers the HTML branch of a respond_to block.
    def render_errors(record, status: 422)
      json({ errors: record.errors.to_jsonapi(status: status) }, status)
    end

    # JSON:API-lite "not found" error, the 404 counterpart to render_errors.
    # No `source.pointer` (unlike a validation error, a missing resource
    # does not point at one attribute of it).
    def render_not_found(detail, status: 404)
      json({ errors: [{ status: status.to_s, title: 'Resource Not Found', detail: detail }] }, status)
    end

    def html(markup, code = nil)
      @response.status = code if code
      @response['Content-Type'] = 'text/html;charset=utf-8'
      @response.body = [markup]
      markup
    end

    # ActionController::Live-lite: `stream { |out| out.write(row) }` sends
    # the response as HTTP/1.1 chunked Transfer-Encoding instead of
    # buffering the whole body first - see Prism::StreamingBody and
    # Server#write_response. Nothing inside the block runs here; it only
    # runs once the server starts sending the response (see Response#stream).
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
      router = @env['prism.router'] || raise('no router available for url_for')
      router.path_to(name, params)
    end

    def finalize_flash
      @flash.sweep if @flash
    end

    # Locale for this request: an explicit ?locale= param wins, then a
    # sticky value stashed in the session, then the client's
    # Accept-Language header, then Prism::I18n.default_locale.
    def locale
      @locale ||= detect_locale
    end

    def translate(key, **options)
      Prism::I18n.t(key, locale: options.delete(:locale) || locale, **options)
    end
    alias_method :t, :translate

    def localize(value, **options)
      Prism::I18n.l(value, locale: options.delete(:locale) || locale, **options)
    end
    alias_method :l, :localize

    private

    def detect_locale
      requested = params['locale'] || session[:locale]
      return requested.to_sym if requested && available_locale?(requested)

      negotiated = Prism::I18n.best_locale_from_accept(@request.headers['Accept-Language'])
      negotiated || Prism::I18n.default_locale
    end

    def available_locale?(candidate)
      Prism::I18n.available_locales.map(&:to_s).include?(candidate.to_s)
    end
  end
end
