module Prism
  class Application
    include Renderable

    class << self
      def router
        @router ||= Router.new
      end

      def middleware_stack
        @middleware_stack ||= MiddlewareStack.new
      end

      def before_filters
        @before_filters ||= []
      end

      def after_filters
        @after_filters ||= []
      end

      def prefix_stack
        @prefix_stack ||= []
      end

      def settings
        @settings ||= { views: 'views' }
      end

      def set(key, value)
        settings[key] = value
      end

      def use(middleware, *args, **kwargs, &block)
        middleware_stack.use(middleware, *args, **kwargs, &block)
        reset_stack!
      end

      def enable_sessions(secret:, **options)
        set(:session_secret, secret)
        use(Middleware::Session, secret: secret, **options)
      end

      def helpers(&block)
        class_eval(&block)
      end

      %w[get post put patch delete options head].each do |verb|
        define_method(verb) do |pattern, to: nil, as: nil, &block|
          router.add(verb, join_prefix(pattern), name: as, to: to, &block)
        end
      end

      def root(to:)
        get('/', to: to, as: :root)
      end

      def resources(name, only: nil, except: nil, param: :id)
        wanted = only || RestActions
        wanted = wanted - Array(except) if except
        singular = Inflector.singularize(name.to_s)
        (RestActions & wanted).each { |action| add_resource_route(name, action, singular, param) }
      end

      def group(prefix)
        prefix_stack.push(prefix)
        yield
      ensure
        prefix_stack.pop
      end

      def before(pattern = nil, &block)
        before_filters << [pattern ? PathMatcher.new(join_prefix(pattern)) : nil, block]
      end

      def after(pattern = nil, &block)
        after_filters << [pattern ? PathMatcher.new(join_prefix(pattern)) : nil, block]
      end

      def call(env)
        built.call(env)
      end

      def built
        @built ||= middleware_stack.build(->(env) { new.dispatch(env) })
      end

      def reset_stack!
        @built = nil
      end

      private

      RestActions = %i[index new create show edit update destroy].freeze

      def add_resource_route(name, action, singular, param)
        base = "/#{name}"
        controller = name.to_s
        case action
        when :index then router.add('GET', join_prefix(base), name: name, to: "#{controller}#index")
        when :new then router.add('GET', join_prefix("#{base}/new"), name: "new_#{singular}", to: "#{controller}#new")
        when :create then router.add('POST', join_prefix(base), to: "#{controller}#create")
        when :show then router.add('GET', join_prefix("#{base}/:#{param}"), name: singular, to: "#{controller}#show")
        when :edit then router.add('GET', join_prefix("#{base}/:#{param}/edit"), name: "edit_#{singular}", to: "#{controller}#edit")
        when :update
          router.add('PATCH', join_prefix("#{base}/:#{param}"), to: "#{controller}#update")
          router.add('PUT', join_prefix("#{base}/:#{param}"), to: "#{controller}#update")
        when :destroy then router.add('DELETE', join_prefix("#{base}/:#{param}"), to: "#{controller}#destroy")
        end
      end

      def join_prefix(pattern)
        return pattern if prefix_stack.empty?
        prefix_stack.join + pattern
      end
    end

    attr_reader :request, :response, :env

    def dispatch(env)
      @env = env
      @env['prism.router'] = self.class.router
      @request = Request.new(env)
      @response = Response.new
      head = @request.request_method == 'HEAD'
      lookup_method = head ? 'GET' : @request.request_method

      catch(:halt) do
        run_before_filters
        matched = run_routes(lookup_method)
        handle_not_found unless matched
      end
      catch(:halt) do
        run_after_filters
      end
      finalize_flash

      status, headers, body = @response.finish
      body = [] if head
      [status, headers, body]
    end

    def erb(template, locals: {})
      source = template.is_a?(Symbol) ? load_template(template) : template
      Template.render(source, locals)
    end
    alias_method :render, :erb

    private

    def run_before_filters
      self.class.before_filters.each do |matcher, block|
        next if matcher && matcher.match(@request.path).nil?
        instance_exec(&block)
      end
    end

    def run_after_filters
      self.class.after_filters.each do |matcher, block|
        next if matcher && matcher.match(@request.path).nil?
        instance_exec(&block)
      end
    end

    def run_routes(lookup_method)
      self.class.router.matches(lookup_method, @request.path).each do |route, path_params|
        @request.path_params = path_params
        outcome = catch(:pass) do
          route.controller_route? ? dispatch_to_controller(route) : finalize_body(instance_exec(&route.block))
          :handled
        end
        return true if outcome == :handled
      end
      false
    end

    def dispatch_to_controller(route)
      controller_class = Object.const_get("#{Inflector.camelize(route.controller_name)}Controller")
      controller = controller_class.new(@env, route.action_name, @request.path_params)
      status, headers, body = controller.process
      @response.status = status
      headers.each { |name, value| @response[name] = value }
      @response.body = body
    end

    def finalize_body(result)
      return unless @response.body.empty?
      @response.body = [result.to_s] if result.is_a?(String)
    end

    def handle_not_found
      @response.status = 404
      @response.body = ["Not Found: #{@request.request_method} #{@request.path}"]
    end

    def load_template(name)
      directory = self.class.settings[:views] || 'views'
      File.read(File.join(directory, "#{name}.erb"))
    end
  end
end
