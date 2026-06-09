module Prism
  # DSL context yielded (via instance_eval) inside `resources ... do ... end`
  # and `resource ... do ... end` blocks. Provides member/collection routes
  # and nesting further resources under the current one.
  class ResourceScope
    def initialize(app, name, singular, param)
      @app = app
      @name = name
      @singular = singular
      @param = param
    end

    # Extra actions scoped to one member: /name/:id/action -> name#action,
    # named "action_singular" (e.g. `publish_post`).
    def member(&block)
      require_member_param!
      @app.group("/#{@name}/:#{@param}") do
        MemberCollectionScope.new(@app, @singular, @name, :member).instance_eval(&block)
      end
    end

    # Extra actions scoped to the whole collection: /name/action -> name#action,
    # named "action_name" (e.g. `search_posts`).
    def collection(&block)
      @app.group("/#{@name}") do
        MemberCollectionScope.new(@app, @singular, @name, :collection).instance_eval(&block)
      end
    end

    # Nested resources, scoped under this resource: for a plural parent
    # that's /name/:singular_id/nested_name/... (Rails' classic nested
    # routing); for a singular parent (no id at all) it's just
    # /name/nested_name/....
    def resources(nested_name, **options, &block)
      @app.group(nested_prefix) { @app.resources(nested_name, **options, &block) }
    end

    def resource(nested_name, **options, &block)
      @app.group(nested_prefix) { @app.resource(nested_name, **options, &block) }
    end

    private

    def nested_prefix
      @param ? "/#{@name}/:#{@singular}_id" : "/#{@name}"
    end

    def require_member_param!
      return if @param
      raise ArgumentError, 'member/collection routes need an id segment; not available on a singular resource'
    end
  end

  # DSL context for the block passed to ResourceScope#member/#collection.
  class MemberCollectionScope
    def initialize(app, singular, plural, kind)
      @app = app
      @singular = singular
      @plural = plural
      @kind = kind
    end

    %w[get post put patch delete].each do |verb|
      define_method(verb) do |action, to: nil, as: nil|
        controller_action = to || "#{@plural}##{action}"
        name = as || default_name(action)
        @app.public_send(verb, "/#{action}", to: controller_action, as: name)
      end
    end

    private

    def default_name(action)
      @kind == :member ? "#{action}_#{@singular}" : "#{action}_#{@plural}"
    end
  end
end
