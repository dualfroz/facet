module Prism
  module Orm
    # ActiveRecord::Enum-lite: maps a column's raw stored value (usually an
    # Integer, but any comparable value works) to a String label, Rails'
    # dual call syntax supported both ways:
    #
    #   enum :status, { draft: 0, published: 1, archived: 2 }
    #   enum status: { draft: 0, published: 1 }, role: { user: 0, admin: 1 }
    #
    # Declaring `enum :status, {...}` on a model defines, per mapping key:
    #   - the attribute reader/writer (`post.status` => "published" String,
    #     `post.status = :published`/`"published"`/the raw Integer all set
    #     the same underlying column)
    #   - a predicate (`post.published?`)
    #   - a persisting bang setter (`post.published!`, sets then `save!`)
    #   - a class-level scope built on the existing `scope` DSL
    #     (`Post.published` => `Post.where(status: 1)`, so it composes with
    #     default_scope/where/order/includes like any hand-written scope)
    #   - the reverse mapping accessor (`Post.statuses` =>
    #     {"draft"=>0, "published"=>1, "archived"=>2})
    #
    # Assigning a value outside the mapping raises ArgumentError immediately
    # (matches Rails - a typo'd enum value fails loudly at the call site,
    # not as a mysterious later validation error or silently stored garbage).
    module Enum
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Same superclass-plus-own fallback as Callbacks#callbacks_for and
        # Serialization#json_hidden_attributes - a plain `@ivar ||= {}` per
        # class would drop a base model's enums in every subclass.
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

        # Translates a value assigned to an enum attribute (Symbol, String,
        # or the raw stored value itself) into the raw value to persist.
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

      # Enum columns serialize to their String label (Rails behavior), not
      # the raw stored value - relies on Enum being included after
      # Serialization in Model, so it sits closer to Model in the ancestor
      # chain and `super` reaches Serialization#serializable_hash.
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
