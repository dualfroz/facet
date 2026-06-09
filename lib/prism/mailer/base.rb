module Prism
  module Mailer
    # ActionMailer-lite: subclass, declare `default from: '...'`, define an
    # instance method per mailer action that ends with a call to #mail.
    # Calling the action as a class method (`WelcomeMailer.welcome(user)`)
    # renders the templates immediately and returns a Delivery.
    class Base
      class << self
        def default(options = nil)
          @default_options = (@default_options || {}).merge(options) if options
          @default_options || {}
        end

        def template_roots
          @template_roots || [File.join(Dir.pwd, 'app', 'views', 'mailers')]
        end

        attr_writer :template_roots

        # Per-mailer-class override of Mailer.default_url_options, merged
        # over it (this class's values win) by #url_for.
        def default_url_options(options = nil)
          @default_url_options = (@default_url_options || {}).merge(options) if options
          @default_url_options || {}
        end

        def mailer_name
          Inflector.underscore(name.to_s.split('::').last.sub(/Mailer\z/, ''))
        end

        def method_missing(name, *args, &block)
          return super unless instance_methods(false).include?(name)

          instance = new
          instance.send(:run_action, name, args)
          Delivery.new(instance.message, mailer_class: self, action_name: name.to_s, args: args)
        end

        def respond_to_missing?(name, include_private = false)
          instance_methods(false).include?(name) || super
        end
      end

      attr_reader :message, :action_name

      def initialize
        @message = Message.new
        apply_defaults
      end

      def mail(to:, subject:, from: nil, cc: nil, bcc: nil, reply_to: nil, template: nil, locals: {})
        message.to = to
        message.subject = subject
        message.from = from if from
        message.cc = cc if cc
        message.bcc = bcc if bcc
        message.reply_to = reply_to if reply_to
        render_bodies(template || action_name, locals)
        message
      end

      # Absolute URL for a named route, for use inside mailer actions and
      # templates (there is no incoming request to infer a host from, unlike
      # Controller#url_for). Requires Mailer.router to be set and a :host
      # somewhere in Mailer.default_url_options / self.class.default_url_options
      # / the params passed here.
      def url_for(name, params = {})
        router = Mailer.router
        raise 'no router configured; set Prism::Mailer.router before generating mailer URLs' unless router

        options = Mailer.default_url_options.merge(self.class.default_url_options).merge(params)
        host = options.delete(:host)
        raise ArgumentError, 'default_url_options must include :host to build a mailer URL' unless host

        protocol = options.delete(:protocol) || 'http'
        port = options.delete(:port)
        "#{protocol}://#{host}#{port ? ":#{port}" : ''}#{router.path_to(name, options)}"
      end

      private

      def run_action(name, args)
        @action_name = name.to_s
        public_send(name, *args)
      end

      def apply_defaults
        self.class.default.each do |key, value|
          message.public_send("#{key}=", value)
        end
      end

      def render_bodies(name, locals)
        view = Prism::View.new(self.class.template_roots, helpers: self)
        merged_locals = auto_locals.merge(locals)
        found_any = false

        begin
          message.text_body = view.render("#{self.class.mailer_name}/#{name}.text", locals: merged_locals)
          found_any = true
        rescue Prism::View::TemplateNotFound
          nil
        end

        begin
          message.html_body = view.render("#{self.class.mailer_name}/#{name}.html", locals: merged_locals)
          found_any = true
        rescue Prism::View::TemplateNotFound
          nil
        end

        return if found_any

        raise Prism::View::TemplateNotFound,
              "no mailer template #{name}.text.erb or #{name}.html.erb for " \
              "#{self.class.mailer_name} in #{self.class.template_roots.join(', ')}"
      end

      def auto_locals
        instance_variables.each_with_object({}) do |ivar, locals|
          next if %i[@message @action_name].include?(ivar)

          locals[ivar.to_s.delete_prefix('@').to_sym] = instance_variable_get(ivar)
        end
      end
    end
  end
end
