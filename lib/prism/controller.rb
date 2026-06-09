module Prism
  class Controller
    include Renderable
    include ConditionalGet

    class << self
      # Combines this controller's own filters with everything declared on
      # its ancestors, ancestors first, so a shared ApplicationController can
      # declare `protect_from_forgery`/`before_action :require_authentication`
      # once and have every subclass run it - the same way `layout`/
      # `views_root` already fall back to the superclass.
      def before_actions
        own = @before_actions ||= []
        superclass.respond_to?(:before_actions) ? superclass.before_actions + own : own
      end

      def after_actions
        own = @after_actions ||= []
        superclass.respond_to?(:after_actions) ? superclass.after_actions + own : own
      end

      # Own handlers first (most recently declared first, like Rails'
      # reverse-declaration-order matching), then the superclass's - so an
      # ApplicationController-wide `rescue_from StandardError` never shadows
      # a more specific handler a subclass declares for itself.
      def rescue_handlers
        own = (@rescue_handlers ||= []).reverse
        superclass.respond_to?(:rescue_handlers) ? own + superclass.rescue_handlers : own
      end

      def rescue_from(*exception_classes, with: nil, &block)
        raise ArgumentError, 'rescue_from needs with: or a block' unless with || block
        exception_classes.each { |klass| (@rescue_handlers ||= []) << { klass: klass, with: with, block: block } }
      end

      def before_action(*names, only: nil, except: nil, &block)
        register_filter(@before_actions ||= [], names, only, except, block)
      end

      def after_action(*names, only: nil, except: nil, &block)
        register_filter(@after_actions ||= [], names, only, except, block)
      end

      def protect_from_forgery(only: nil, except: nil)
        before_action(:verify_authenticity_token!, only: only, except: except)
      end

      def layout(name = :missing)
        @layout = name unless name == :missing
        defined?(@layout) ? @layout : superclass_layout
      end

      def views_root(path = nil)
        @views_root = path if path
        @views_root || superclass_views_root || 'app/views'
      end

      # "posts" for PostsController, "admin/posts" for Admin::PostsController
      # (keeps the full module path so namespaced views live under
      # app/views/admin/posts/, matching Rails' convention).
      def controller_path
        Inflector.underscore(name.to_s.sub(/Controller\z/, ''))
      end

      private

      def superclass_layout
        superclass.respond_to?(:layout) ? superclass.layout : nil
      end

      def superclass_views_root
        superclass.respond_to?(:views_root) ? superclass.views_root : nil
      end

      def register_filter(store, names, only, except, block)
        names.each { |name| store << { name: name, block: nil, only: only, except: except } }
        store << { name: nil, block: block, only: only, except: except } if block
      end
    end

    attr_reader :request, :response, :env, :action_name

    def initialize(env, action_name, path_params = {})
      @env = env
      @request = Request.new(env)
      @request.path_params = path_params
      @response = Response.new
      @action_name = action_name.to_s
    end

    def process
      catch(:halt) do
        begin
          run_before_actions
          finalize_body(send(@action_name))
        rescue StandardError => e
          handle_exception(e)
        end
      end
      catch(:halt) { run_after_actions }
      finalize_flash
      @response.finish
    end

    def render(view = action_name, layout: self.class.layout, locals: {})
      content = view_resolver.render("#{self.class.controller_path}/#{view}", locals: locals, layout: layout)
      html(content)
    end

    def partial(name, locals: {})
      view_resolver.render_partial(partial_path(name), locals: locals)
    end

    def render_each(name, collection, locals: {}, as: nil)
      view_resolver.render_collection(partial_path(name), collection, locals: locals, as: as)
    end

    # Rails-style content negotiation: `respond_to { |f| f.html { render }; f.json { json(x) } }`.
    # Renders 406 when the negotiated format (see Request#format) has no matching block.
    def respond_to
      responder = Responder.new
      yield responder
      format = request.format
      responder.respond(format)
    rescue Responder::UnknownFormat
      halt(406, "Not Acceptable: #{format}")
    end

    private

    UnsafeMethods = %w[POST PUT PATCH DELETE].freeze

    def verify_authenticity_token!
      return unless UnsafeMethods.include?(@request.request_method)
      token = params['authenticity_token'] || @request.headers['X-Csrf-Token']
      halt(422, 'invalid authenticity token') unless csrf.valid_token?(token)
    end

    # Finds the most specific registered `rescue_from` handler (`is_a?`
    # against the raised exception) and runs it - the handler is expected
    # to finish the response itself (`halt`/`render`/`redirect`), the same
    # contract Rails' rescue_from has. Re-raises when nothing matches, so
    # an unhandled exception still reaches the application-level fallback.
    def handle_exception(exception)
      handler = self.class.rescue_handlers.find { |candidate| exception.is_a?(candidate[:klass]) }
      raise exception unless handler
      handler[:block] ? instance_exec(exception, &handler[:block]) : send(handler[:with], exception)
    end

    def finalize_body(result)
      return if @response.streaming?
      return unless @response.body.empty?
      @response.body = [result.to_s] if result.is_a?(String)
    end

    def partial_path(name)
      name.to_s.include?('/') ? name.to_s : "#{self.class.controller_path}/#{name}"
    end

    def view_resolver
      @view_resolver ||= View.new(self.class.views_root, helpers: self)
    end

    def run_before_actions
      self.class.before_actions.each { |filter| run_filter(filter) }
    end

    def run_after_actions
      self.class.after_actions.each { |filter| run_filter(filter) }
    end

    def run_filter(filter)
      return unless applies?(filter)
      filter[:block] ? instance_exec(&filter[:block]) : send(filter[:name])
    end

    def applies?(filter)
      action = @action_name.to_sym
      return filter[:only].include?(action) if filter[:only]
      return !filter[:except].include?(action) if filter[:except]
      true
    end
  end
end
