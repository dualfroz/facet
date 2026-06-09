module Prism
  # Rack::Cors-lite: a small registry of cross-origin rules, matched by
  # allowed origin then by resource path pattern. Prism::Middleware::Cors
  # reads this registry on every request; it holds no per-request state.
  module Cors
    class Resource
      attr_reader :pattern, :methods, :headers, :expose, :credentials, :max_age

      def initialize(pattern, methods: %w[GET], headers: :any, expose: [], credentials: false, max_age: nil)
        @pattern = pattern
        @methods = Array(methods).map { |m| m.to_s.upcase }
        @headers = headers == :any ? :any : Array(headers).map(&:downcase)
        @expose = Array(expose)
        @credentials = credentials
        @max_age = max_age
      end

      def match?(path)
        File.fnmatch(pattern, path)
      end

      def allows_method?(method)
        methods.include?(method.to_s.upcase)
      end

      def allows_headers?(requested)
        return true if headers == :any
        requested_list = requested.to_s.split(',').map { |h| h.strip.downcase }.reject(&:empty?)
        requested_list.all? { |h| headers.include?(h) }
      end
    end

    class Rule
      def initialize
        @origins = []
        @resources = []
      end

      def origins(*list)
        @origins = list.flatten
      end

      def resource(pattern, **options)
        @resources << Resource.new(pattern, **options)
      end

      def allows_origin?(origin)
        return false if origin.nil? || origin.empty?
        @origins.any? do |allowed|
          case allowed
          when '*' then true
          when Regexp then allowed.match?(origin)
          else allowed == origin
          end
        end
      end

      def resource_for(path)
        @resources.find { |resource| resource.match?(path) }
      end
    end

    class Configuration
      attr_reader :rules

      def initialize
        @rules = []
      end

      def allow(&block)
        rule = Rule.new
        rule.instance_eval(&block)
        @rules << rule
        rule
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def reset!
        @configuration = Configuration.new
      end

      # Returns the [Rule, Resource] pair matching this origin/path, or nil.
      def resource_for(origin, path)
        configuration.rules.each do |rule|
          next unless rule.allows_origin?(origin)
          resource = rule.resource_for(path)
          next unless resource
          return [rule, resource]
        end
        nil
      end
    end
  end
end
