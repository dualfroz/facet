module Prism
  module Orm
    # Mixed into Relation/HabtmCollection so `json(Post.all)`/`render json:
    # post.comments` works the same way as a single record: each element is
    # serialized through Model#as_json (so hide_from_json still applies to
    # every record in the collection, not just a lone one).
    module CollectionSerialization
      def as_json(options = {})
        to_a.map { |record| record.as_json(options) }
      end

      def to_json(*args)
        as_json.to_json(*args)
      end
    end

    # ActiveModel::Serialization-lite: turns a record into a plain Hash
    # (#serializable_hash) or a JSON string (#as_json/#to_json), Rails-style
    # only:/except:/methods:/include:.
    #
    # Before this existed, `render json: record`/`json(record)` fell through
    # to the stdlib json library's default Object#to_json (String#to_json of
    # #to_s, e.g. "#<Post:0x...>") and hand-built hashes in controllers had
    # no protection against leaking a raw column - notably SecurePassword's
    # digest column, since Model#to_h dumps every attribute unfiltered.
    # `hide_from_json` closes that: a class can mark a column excluded by
    # default, and an explicit `only:` naming it is the one way to opt back
    # in (a deliberate ask overrides the safety net, it does not disable it).
    module Serialization
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Same superclass-plus-own fallback as Callbacks#callbacks_for /
        # Controller#before_actions - a plain `@ivar ||= []` per class would
        # silently drop a base class's hidden columns in every subclass.
        def json_hidden_attributes
          inherited = superclass.respond_to?(:json_hidden_attributes) ? superclass.json_hidden_attributes : []
          inherited + own_json_hidden_attributes
        end

        def hide_from_json(*names)
          own_json_hidden_attributes.concat(names.map(&:to_s))
        end

        def own_json_hidden_attributes
          @own_json_hidden_attributes ||= []
        end
      end

      def serializable_hash(only: nil, except: nil, methods: nil, include: nil)
        only_names = only && Array(only).map(&:to_s)
        except_names = Array(except).map(&:to_s)
        hidden = self.class.json_hidden_attributes

        hash = to_h.each_with_object({}) do |(key, value), acc|
          allowed = only_names ? only_names.include?(key) : !hidden.include?(key) && !except_names.include?(key)
          acc[key] = value if allowed
        end

        Array(methods).each { |name| hash[name.to_s] = send(name) }
        merge_included_associations(hash, include) if include
        hash
      end

      def as_json(options = {})
        jsonify(serializable_hash(**options))
      end

      def to_json(*args)
        as_json.to_json(*args)
      end

      private

      def jsonify(value)
        case value
        when Hash then value.transform_values { |nested| jsonify(nested) }
        when Array then value.map { |nested| jsonify(nested) }
        when Time, Date, DateTime then value.iso8601
        else value
        end
      end

      def merge_included_associations(hash, include)
        normalize_include(include).each do |name, nested_options|
          associated = send(name)
          hash[name.to_s] = serialize_association(associated, nested_options || {})
        end
      end

      def serialize_association(associated, nested_options)
        if associated.is_a?(Model)
          associated.serializable_hash(**nested_options)
        elsif associated.respond_to?(:map)
          associated.map { |record| record.serializable_hash(**nested_options) }
        end
      end

      def normalize_include(include)
        case include
        when Symbol, String then { include.to_sym => nil }
        when Array then include.each_with_object({}) { |name, acc| acc[name.to_sym] = nil }
        when Hash then include
        else {}
        end
      end
    end
  end
end
