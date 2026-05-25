module Prism
  class PathMatcher
    attr_reader :keys, :pattern

    def initialize(pattern)
      @pattern = pattern
      @keys = []
      @regex = compile(pattern)
    end

    def match(path)
      data = @regex.match(path)
      return nil unless data
      extract(data)
    end

    def build(params)
      params = params.transform_keys(&:to_s)
      path = +''
      @pattern.scan(/:\w+|\*|[^:*]+/).each do |token|
        if token.start_with?(':')
          key = token[1..]
          value = params.fetch(key) { raise ArgumentError, "missing route param #{key.inspect} for #{@pattern}" }
          path << CGI.escape(value.to_s).gsub('+', '%20')
        elsif token == '*'
          path << params.fetch('splat', '').to_s
        else
          path << token
        end
      end
      path
    end

    private

    def compile(pattern)
      source = +'\A'
      pattern.scan(/:\w+|\*|[^:*]+/).each do |token|
        if token.start_with?(':')
          @keys << token[1..]
          source << '([^/]+)'
        elsif token == '*'
          @keys << 'splat'
          source << '(.*?)'
        else
          source << Regexp.escape(token)
        end
      end
      source << '\z'
      Regexp.new(source)
    end

    def extract(data)
      params = {}
      splats = []
      @keys.each_with_index do |key, index|
        value = data.captures[index]
        if key == 'splat'
          splats << value
        else
          params[key] = CGI.unescape(value)
        end
      end
      params['splat'] = splats unless splats.empty?
      params
    end
  end

  class Route
    attr_reader :method, :block, :name, :controller_name, :action_name

    def initialize(method, pattern, block: nil, name: nil, to: nil)
      @method = method
      @matcher = PathMatcher.new(pattern)
      @block = block
      @name = name&.to_sym
      @controller_name, @action_name = to&.split('#', 2)
    end

    def controller_route?
      !@controller_name.nil?
    end

    def match(request_method, path)
      return nil unless @method == request_method
      @matcher.match(path)
    end

    def path(params = {})
      @matcher.build(params)
    end
  end

  class Router
    attr_reader :routes

    def initialize
      @routes = []
      @named_routes = {}
    end

    def add(method, pattern, name: nil, to: nil, &block)
      route = Route.new(method.to_s.upcase, pattern, block: block, name: name, to: to)
      @routes << route
      @named_routes[name.to_sym] = route if name
      route
    end

    def matches(request_method, path)
      @routes.filter_map do |route|
        params = route.match(request_method, path)
        [route, params] if params
      end
    end

    def path_to(name, params = {})
      route = @named_routes.fetch(name.to_sym) { raise ArgumentError, "no named route #{name.inspect}" }
      route.path(params)
    end
  end
end
