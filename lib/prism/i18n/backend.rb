module Prism
  module I18n
    # Holds translations for every locale as a nested Hash, keyed by symbol
    # at every level ("posts.title" -> { posts: { title: "..." } }).
    # Loaded from plain JSON files (no YAML/psych dependency - this build
    # of Ruby has neither) or stored programmatically.
    class Backend
      def initialize
        @translations = {}
      end

      def store_translations(locale, data)
        locale = locale.to_sym
        @translations[locale] ||= {}
        deep_merge!(@translations[locale], symbolize(data))
      end

      def load_file(path)
        locale = File.basename(path, '.*').to_sym
        data = JSON.parse(File.read(path))
        store_translations(locale, data)
        locale
      end

      def lookup(locale, key)
        segments = key.to_s.split('.').map(&:to_sym)
        root = @translations[locale.to_sym]
        return nil unless root
        segments.reduce(root) do |node, segment|
          return nil unless node.is_a?(Hash)
          node[segment]
        end
      end

      def locales
        @translations.keys
      end

      def clear!
        @translations = {}
      end

      private

      def symbolize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, nested), acc| acc[key.to_sym] = symbolize(nested) }
        when Array
          value.map { |entry| symbolize(entry) }
        else
          value
        end
      end

      def deep_merge!(target, source)
        source.each do |key, value|
          if value.is_a?(Hash) && target[key].is_a?(Hash)
            deep_merge!(target[key], value)
          else
            target[key] = value
          end
        end
        target
      end
    end
  end
end
