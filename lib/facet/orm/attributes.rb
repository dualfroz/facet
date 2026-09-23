module Facet
  module Orm
    module Attributes
      NO_DEFAULT = Object.new.freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def own_attribute_types
          @own_attribute_types ||= {}
        end

        def own_attribute_defaults
          @own_attribute_defaults ||= {}
        end

        def attribute_types
          inherited = superclass.respond_to?(:attribute_types) ? superclass.attribute_types : {}
          inherited.merge(own_attribute_types)
        end

        def attribute_defaults
          inherited = superclass.respond_to?(:attribute_defaults) ? superclass.attribute_defaults : {}
          inherited.merge(own_attribute_defaults)
        end

        def attribute(name, type, default: NO_DEFAULT)
          name = name.to_s
          own_attribute_types[name] = type
          own_attribute_defaults[name] = default unless default.equal?(NO_DEFAULT)

          define_method(name) { TypeCasting.cast(type, self[name]) }
          define_method("#{name}=") { |value| self[name] = TypeCasting.cast(type, value) }
        end
      end

      private

      def apply_attribute_defaults
        self.class.attribute_defaults.each do |name, default|
          next unless self[name].nil?
          raw = default.is_a?(Proc) ? instance_exec(&default) : default
          self[name] = TypeCasting.cast(self.class.attribute_types[name], raw)
        end
      end
    end
  end
end
