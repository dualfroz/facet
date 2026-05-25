module Prism
  class MiddlewareStack
    def initialize
      @entries = []
    end

    def use(middleware, *args, **kwargs, &block)
      @entries << [middleware, args, kwargs, block]
    end

    def build(app)
      @entries.reverse.reduce(app) do |inner, (middleware, args, kwargs, block)|
        if kwargs.empty?
          middleware.new(inner, *args, &block)
        else
          middleware.new(inner, *args, **kwargs, &block)
        end
      end
    end

    def empty?
      @entries.empty?
    end
  end
end
