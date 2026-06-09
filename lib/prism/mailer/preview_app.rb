module Prism
  module Mailer
    # A tiny Rack app that browses Mailer::Preview subclasses in a web
    # browser, mirroring Rails' /rails/mailers engine: an index of every
    # registered preview, a list of its actions, and a rendered view of one
    # email (HTML part if present, raw text part otherwise) - all without
    # ever touching Mailer.deliver!. Mount it directly:
    #   BlogApp.mount('/rails/mailers', Prism::Mailer::PreviewApp.new)
    class PreviewApp
      def call(env)
        request = Request.new(env)
        return not_found unless request.request_method == 'GET'

        # Links are built from SCRIPT_NAME (where this app was mounted)
        # rather than relative to PATH_INFO, so they work the same whether
        # this is mounted at "/rails/mailers" or served standalone at "/" -
        # relative hrefs would break the moment the current path lacks a
        # trailing slash (the classic Rack::URLMap gotcha).
        @base = env['SCRIPT_NAME'].to_s
        segments = request.path.split('/').reject(&:empty?)
        case segments.length
        when 0 then index
        when 1 then show_preview(segments[0])
        when 2 then show_email(segments[0], segments[1])
        else not_found
        end
      rescue ArgumentError
        not_found
      end

      private

      def index
        previews = Preview.registry.sort_by(&:preview_name)
        items = previews.map do |klass|
          %(<li><a href="#{@base}/#{klass.preview_name}">#{escape(klass.preview_name)}</a></li>)
        end
        body = "<h1>Mailer previews</h1><ul>#{items.join}</ul>"
        body = '<h1>Mailer previews</h1><p>No previews registered.</p>' if previews.empty?
        html(body)
      end

      def show_preview(name)
        klass = Preview.find(name)
        return not_found unless klass

        items = klass.emails.map do |email|
          %(<li><a href="#{@base}/#{klass.preview_name}/#{email}">#{escape(email)}</a></li>)
        end
        body = +%(<p><a href="#{@base}">&laquo; all previews</a></p>)
        body << "<h1>#{escape(klass.preview_name)}</h1><ul>#{items.join}</ul>"
        html(body)
      end

      def show_email(name, email)
        klass = Preview.find(name)
        return not_found unless klass

        delivery = klass.call(email)
        html(render_message(klass, email, delivery.message))
      end

      def render_message(klass, email, message)
        body = +%(<p><a href="#{@base}/#{klass.preview_name}">&laquo; #{escape(klass.preview_name)}</a></p>)
        body << "<h1>#{escape(klass.preview_name)}##{escape(email)}</h1>"
        body << '<dl>'
        body << "<dt>Subject</dt><dd>#{escape(message.subject)}</dd>"
        body << "<dt>From</dt><dd>#{escape(message.from)}</dd>"
        body << "<dt>To</dt><dd>#{escape(message.to.join(', '))}</dd>"
        body << '</dl><hr>'
        body << render_body(message)
        body
      end

      def render_body(message)
        if message.html_body
          message.html_body
        elsif message.text_body
          "<pre>#{escape(message.text_body)}</pre>"
        else
          '<p><em>empty body</em></p>'
        end
      end

      def escape(text)
        CGI.escapeHTML(text.to_s)
      end

      def html(body)
        [200, { 'Content-Type' => 'text/html; charset=UTF-8' },
         ["<!doctype html><html><head><meta charset=\"utf-8\"></head><body>#{body}</body></html>"]]
      end

      def not_found
        [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
      end
    end
  end
end
