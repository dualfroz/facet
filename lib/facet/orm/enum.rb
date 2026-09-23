module Facet
  module Orm
    module Enum
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def enum_definitions
          inherited = superclass.respond_to?(:enum_definitions) ? superclass.enum_definitions : {}
          inherited.merge(own_enum_definitions)
        end

        def own_enum_definitions
          @own_enum_definitions ||= {}
        end

        def enum(name = nil, mapping = nil, prefix: nil, suffix: nil, **columns)
          define_enum(name, mapping, prefix: prefix, suffix: suffix) if name
          columns.each { |column, column_mapping| define_enum(column, column_mapping, prefix: prefix, suffix: suffix) }
        end

        def enum_cast(attribute, value)
          mapping = enum_definitions.fetch(attribute.to_s) { raise ArgumentError, "unknown enum #{attribute}" }
          return nil if value.nil?
          key = value.is_a?(Symbol) ? value.to_s : value
          return mapping[key] if key.is_a?(String) && mapping.key?(key)
          return value if mapping.value?(value)
          raise ArgumentError, "#{value.inspect} is not a valid #{attribute}"
        end

        private

        def define_enum(name, mapping, prefix:, suffix:)
          name = name.to_s
          mapping = mapping.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
          raise ArgumentError, "duplicate raw value in enum #{name}" if mapping.values.uniq.length != mapping.length

          own_enum_definitions[name] = mapping
          reverse = mapping.invert

          define_method(name) { reverse[self[name]] }
          define_method("#{name}=") { |value| self[name] = self.class.enum_cast(name, value) }

          mapping.each_key do |key|
            method_base = enum_method_base(name, key, prefix, suffix)
            define_method("#{method_base}?") { self[name] == mapping[key] }
            define_method("#{method_base}!") do
              send("#{name}=", key)
              save!
            end
            scope(method_base, -> { where(name => mapping[key]) })
          end

          define_singleton_method(Inflector.pluralize(name)) { mapping.dup }
        end

        def enum_method_base(name, key, prefix, suffix)
          base = key
          base = "#{prefix == true ? name : prefix}_#{base}" if prefix
          base = "#{base}_#{suffix == true ? name : suffix}" if suffix
          base
        end
      end

      def serializable_hash(**options)
        hash = super
        self.class.enum_definitions.each do |column, mapping|
          next unless hash.key?(column)
          hash[column] = mapping.invert[self[column]]
        end
        hash
      end
    end
  end
end
