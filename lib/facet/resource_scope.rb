module Facet
  class ResourceScope
    def initialize(app, name, singular, param)
      @app = app
      @name = name
      @singular = singular
      @param = param
    end

    def member(&block)
      require_member_param!
      @app.group("/#{@name}/:#{@param}") do
        MemberCollectionScope.new(@app, @singular, @name, :member).instance_eval(&block)
      end
    end

    def collection(&block)
      @app.group("/#{@name}") do
        MemberCollectionScope.new(@app, @singular, @name, :collection).instance_eval(&block)
      end
    end

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
