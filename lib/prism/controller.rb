module Prism
  class Controller
    include Renderable

    class << self
      def before_actions
        @before_actions ||= []
      end

      def after_actions
        @after_actions ||= []
      end

      def before_action(*names, only: nil, except: nil, &block)
        register_filter(before_actions, names, only, except, block)
      end

      def after_action(*names, only: nil, except: nil, &block)
        register_filter(after_actions, names, only, except, block)
      end

      def layout(name = :missing)
        @layout = name unless name == :missing
        defined?(@layout) ? @layout : superclass_layout
      end

      def views_root(path = nil)
        @views_root = path if path
        @views_root || superclass_views_root || 'app/views'
      end

      def controller_path
        Inflector.underscore(name.to_s.split('::').last.sub(/Controller\z/, ''))
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
        run_before_actions
        finalize_body(send(@action_name))
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

    private

    def finalize_body(result)
      return unless @response.body.empty?
      @response.body = [result.to_s] if result.is_a?(String)
    end

    def partial_path(name)
      name.to_s.include?('/') ? name.to_s : "#{self.class.controller_path}/#{name}"
    end

    def view_resolver
      @view_resolver ||= View.new(self.class.views_root)
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
