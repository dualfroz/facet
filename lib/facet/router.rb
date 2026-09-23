module Facet
  class PathMatcher
    attr_reader :keys, :pattern

    def initialize(pattern, constraints: {}, format: false)
      @pattern = pattern
      @keys = []
      @constraints = constraints.transform_keys(&:to_s)
      @format = format && !pattern.include?('*')
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
          key = token[1..]
          @keys << key
          source << segment_source(key)
        elsif token == '*'
          @keys << 'splat'
          source << '(.*?)'
        else
          source << Regexp.escape(token)
        end
      end
      if @format
        @keys << 'format'
        source << '(?:\.([^/.]+))?'
      end
      source << '\z'
      Regexp.new(source)
    end

    def segment_source(key)
      constraint = @constraints[key]
      return "(#{constraint.source})" if constraint
      @format ? '([^/.]+)' : '([^/]+)'
    end

    def extract(data)
      params = {}
      splats = []
      @keys.each_with_index do |key, index|
        value = data.captures[index]
        next if value.nil?
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
    attr_reader :method, :block, :name, :controller_name, :action_name, :pattern

    def initialize(method, pattern, block: nil, name: nil, to: nil, constraints: {}, format: false)
      @method = method
      @pattern = pattern
      @matcher = PathMatcher.new(pattern, constraints: constraints, format: format)
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
    attr_reader :routes, :mounts, :websockets

    def initialize
      @routes = []
      @named_routes = {}
      @mounts = []
      @websockets = {}
      @websocket_options = {}
    end

    def add(method, pattern, name: nil, to: nil, constraints: {}, format: false, &block)
      route = Route.new(method.to_s.upcase, pattern, block: block, name: name, to: to,
                                                      constraints: constraints, format: format)
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

    def mount(prefix, app)
      prefix = prefix.chomp('/')
      @mounts << [prefix, app]
      @mounts.sort_by! { |mounted_prefix, _| -mounted_prefix.length }
    end

    def find_mount(path)
      @mounts.find { |prefix, _| path == prefix || path.start_with?("#{prefix}/") }
    end

    def add_websocket(path, handler, max_message_size: nil)
      @websockets[path] = handler
      @websocket_options[path] = { max_message_size: max_message_size }
    end

    def find_websocket(path)
      @websockets[path]
    end

    def find_websocket_options(path)
      @websocket_options[path] || {}
    end
  end
end
