module Facet
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

      def module_stack
        @module_stack ||= []
      end

      def name_prefix_stack
        @name_prefix_stack ||= []
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

      def enable_sessions(secret:, previous_secrets: [], **options)
        set(:session_secret, secret)
        set(:session_previous_secrets, previous_secrets)
        use(Middleware::Session, secret: secret, previous_secrets: previous_secrets, **options)
      end

      def enable_attribute_encryption(secret:, previous_secrets: [])
        Orm::Encryption.primary_key = secret
        Orm::Encryption.previous_keys = previous_secrets
      end

      def enable_token_signing(secret:, previous_secrets: [])
        Orm::TokenFor.primary_secret = secret
        Orm::TokenFor.previous_secrets = previous_secrets
      end

      def enable_n_plus_one_detection(threshold: 2, io: $stderr, raise_on_violation: false)
        Orm::NPlusOneDetector.enable!(threshold: threshold, io: io, raise_on_violation: raise_on_violation)
      end

      def enable_mailer(host:, protocol: 'http', port: nil)
        Mailer.router = router
        Mailer.default_url_options = { host: host, protocol: protocol, port: port }.compact
      end

      def enable_assets(source:, output:, prefix: '/assets')
        manifest = Assets::Compiler.new(source: source, output: output).compile!
        Assets.manifest = manifest
        use(Middleware::Assets, root: output, prefix: prefix)
      end

      def helpers(&block)
        class_eval(&block)
      end

      %w[get post put patch delete options head].each do |verb|
        define_method(verb) do |pattern, to: nil, as: nil, constraints: {}, format: false, &block|
          router.add(verb, join_prefix(pattern), name: join_name(as), to: join_controller_action(to),
                                                   constraints: constraints, format: format, &block)
        end
      end

      def root(to:)
        get('/', to: to, as: :root)
      end

      def namespace(name, path: nil, module: true, &block)
        use_module = binding.local_variable_get(:module)
        prefix_stack.push(path || "/#{name}")
        module_stack.push(name.to_s) if use_module
        name_prefix_stack.push(name.to_s)
        yield
      ensure
        prefix_stack.pop
        module_stack.pop if use_module
        name_prefix_stack.pop
      end

      def resources(name, only: nil, except: nil, param: :id, constraints: {}, &block)
        wanted = only || RestActions
        wanted = wanted - Array(except) if except
        singular = Inflector.singularize(name.to_s)
        ResourceScope.new(self, name, singular, param).instance_eval(&block) if block
        (RestActions & wanted).each { |action| add_resource_route(name, action, singular, param, constraints) }
      end

      def resource(name, only: nil, except: nil, &block)
        wanted = only || SingularRestActions
        wanted = wanted - Array(except) if except
        base = "/#{name}"
        controller = name.to_s
        (SingularRestActions & wanted).each do |action|
          case action
          when :new then get("#{base}/new", to: "#{controller}#new", as: "new_#{name}", format: true)
          when :create then post(base, to: "#{controller}#create", format: true)
          when :show then get(base, to: "#{controller}#show", as: name.to_sym, format: true)
          when :edit then get("#{base}/edit", to: "#{controller}#edit", as: "edit_#{name}", format: true)
          when :update
            patch(base, to: "#{controller}#update", format: true)
            put(base, to: "#{controller}#update", format: true)
          when :destroy then delete(base, to: "#{controller}#destroy", format: true)
          end
        end
        ResourceScope.new(self, name, name.to_s, nil).instance_eval(&block) if block
      end

      def mount(path_prefix, app)
        router.mount(join_prefix(path_prefix), app)
      end

      def websocket(path, handler, max_message_size: nil)
        router.add_websocket(join_prefix(path), handler, max_message_size: max_message_size)
      end

      def find_websocket_handler(path)
        router.find_websocket(path)
      end

      def find_websocket_options(path)
        router.find_websocket_options(path)
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
      SingularRestActions = %i[new create show edit update destroy].freeze

      def add_resource_route(name, action, singular, param, constraints = {})
        base = "/#{name}"
        controller = name.to_s
        route_constraints = constraints.transform_keys(&:to_sym).select { |key, _| key == param.to_sym }
        case action
        when :index then get(base, to: "#{controller}#index", as: name, format: true)
        when :new then get("#{base}/new", to: "#{controller}#new", as: "new_#{singular}", format: true)
        when :create then post(base, to: "#{controller}#create", format: true)
        when :show
          get("#{base}/:#{param}", to: "#{controller}#show", as: singular, constraints: route_constraints, format: true)
        when :edit
          get("#{base}/:#{param}/edit", to: "#{controller}#edit", as: "edit_#{singular}", constraints: route_constraints, format: true)
        when :update
          patch("#{base}/:#{param}", to: "#{controller}#update", constraints: route_constraints, format: true)
          put("#{base}/:#{param}", to: "#{controller}#update", constraints: route_constraints, format: true)
        when :destroy
          delete("#{base}/:#{param}", to: "#{controller}#destroy", as: singular, constraints: route_constraints,
                                       format: true)
        end
      end

      def join_prefix(pattern)
        return pattern if prefix_stack.empty?
        prefix_stack.join + pattern
      end

      def join_controller(controller)
        return controller if module_stack.empty?
        "#{module_stack.join('/')}/#{controller}"
      end

      def join_controller_action(to)
        return to unless to
        controller, action = to.split('#', 2)
        "#{join_controller(controller)}##{action}"
      end

      def join_name(name)
        return name if name.nil? || name_prefix_stack.empty?
        "#{name_prefix_stack.join('_')}_#{name}".to_sym
      end
    end

    attr_reader :request, :response, :env

    def dispatch(env)
      @env = env
      @env['facet.router'] = self.class.router
      @request = Request.new(env)
      @response = Response.new
      head = @request.request_method == 'HEAD'
      lookup_method = head ? 'GET' : @request.request_method

      Orm::NPlusOneDetector.reset! if Orm::NPlusOneDetector.enabled?
      Instrumentation.instrument('process_action.facet', method: @request.request_method,
                                                           path: @request.path) do |payload|
        @instrumentation_payload = payload
        catch(:halt) do
          begin
            run_before_filters
            matched = run_routes(lookup_method) || dispatch_mount
            handle_not_found unless matched
          rescue StandardError => e
            handle_uncaught_exception(e)
          end
        end
        catch(:halt) do
          run_after_filters
        end
        finalize_flash
        begin
          Orm::NPlusOneDetector.report!(method: @request.request_method, path: @request.path) if Orm::NPlusOneDetector.enabled?
        rescue Orm::NPlusOneViolation => e
          handle_uncaught_exception(e)
        end
        payload[:status] = @response.status
      end

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
      controller_class = resolve_controller_class(route.controller_name)
      controller = controller_class.new(@env, route.action_name, @request.path_params)
      @instrumentation_payload&.merge!(controller: route.controller_name, action: route.action_name)
      status, headers, body = controller.process
      @response.status = status
      headers.each { |name, value| @response[name] = value }
      @response.body = body
    end

    def dispatch_mount
      mounted = self.class.router.find_mount(@request.path)
      return false unless mounted

      prefix, app = mounted
      path_info = @request.path.delete_prefix(prefix)
      path_info = '/' if path_info.empty?
      mount_env = @env.merge(
        'SCRIPT_NAME' => "#{@env['SCRIPT_NAME']}#{prefix}",
        'PATH_INFO' => path_info
      )
      status, headers, body = app.call(mount_env)
      @response.status = status
      headers.each { |name, value| @response[name] = value }
      @response.body = body
      true
    end

    def finalize_body(result)
      return if @response.streaming?
      return unless @response.body.empty?
      @response.body = [result.to_s] if result.is_a?(String)
    end

    def resolve_controller_class(controller_name)
      segments = controller_name.split('/').map { |segment| Inflector.camelize(segment) }
      Object.const_get("#{segments.join('::')}Controller")
    end

    def handle_not_found
      @response.status = 404
      @response.body = ["Not Found: #{@request.request_method} #{@request.path}"]
    end

    def handle_uncaught_exception(exception)
      @instrumentation_payload[:exception] = [exception.class.name, exception.message]
      @instrumentation_payload[:exception_object] = exception
      @response.status = 500
      @response['Content-Type'] = 'text/plain'
      @response.body = ['Internal Server Error']
    end

    def load_template(name)
      directory = self.class.settings[:views] || 'views'
      File.read(File.join(directory, "#{name}.erb"))
    end
  end
end
