module Prism
  module Orm
    # ActiveModel::Attributes-lite: `attribute :featured, :boolean` casts
    # every read AND write of that column through TypeCasting, and
    # optionally seeds a default before mass-assignment runs.
    #
    # Deliberately opt-in per attribute rather than inferred from the
    # migration's declared column type (`t.boolean :featured`) - Store's
    # schema has never tracked column types past table creation
    # (TableDefinition#column discards its `type` argument), and making
    # every column on every model suddenly cast automatically would be a
    # behavior change no existing model/test asked for. Declaring it
    # explicitly is the same shape as SecurePassword's `password=` or
    # SecureToken's `has_secure_token`: a plain writer method already
    # defined before Model.load_schema! runs, so load_schema! leaves it
    # alone instead of overwriting it with a raw passthrough (see its
    # `next if method_defined?(...)` guard).
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

        # Same superclass-plus-own fallback as Callbacks#callbacks_for/
        # Controller#before_actions/Serialization#json_hidden_attributes -
        # a plain `@ivar ||= {}` per class would silently drop whatever a
        # base model class declared once a subclass declared its own.
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

      # Runs before mass-assignment in Model#initialize so an explicit
      # value passed to .new/.create always wins over the default, and so
      # a default is visible to validations/before_save callbacks even
      # when the caller never mentioned the attribute at all.
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
