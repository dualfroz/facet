module Prism
  # Rails-style allowlisting for request parameters: nothing reaches a
  # model's mass-assignment until it has been explicitly required and
  # permitted, so an attacker cannot smuggle extra columns (e.g. `admin`)
  # into a create/update call just by adding fields to a form.
  class StrongParameters
    class ParameterMissing < StandardError
      def initialize(key)
        super("param is missing or the value is empty: #{key}")
      end
    end

    class UnfilteredParameters < StandardError; end

    def initialize(hash, permitted = false)
      @hash = hash.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      @permitted = permitted
    end

    def permitted?
      @permitted
    end

    def [](key)
      @hash[key.to_s]
    end

    def key?(key)
      @hash.key?(key.to_s)
    end
    alias_method :has_key?, :key?

    def require(key)
      value = self[key]
      raise ParameterMissing, key if blank?(value)
      value.is_a?(Hash) ? self.class.new(value) : value
    end

    def permit(*filters)
      result = {}
      filters.each do |filter|
        case filter
        when Symbol, String then permit_scalar(filter, result)
        when Hash then permit_nested(filter, result)
        else raise ArgumentError, "unsupported permit filter #{filter.inspect}"
        end
      end
      self.class.new(result, true)
    end

    def to_h
      raise UnfilteredParameters, 'unable to convert unpermitted parameters to hash' unless permitted?
      to_unsafe_h
    end

    def to_unsafe_h
      deep_copy(@hash)
    end

    private

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def permit_scalar(filter, result)
      key = filter.to_s
      return unless @hash.key?(key)
      value = @hash[key]
      result[key] = value unless value.is_a?(Hash) || value.is_a?(Array)
    end

    def permit_nested(filter, result)
      filter.each do |raw_key, nested_filters|
        key = raw_key.to_s
        next unless @hash.key?(key)
        value = @hash[key]
        next unless value.is_a?(Hash) || value.is_a?(Array)
        result[key] = permit_nested_value(value, Array(nested_filters))
      end
    end

    def permit_nested_value(value, nested_filters)
      if value.is_a?(Hash)
        indexed_hash?(value) ? permit_indexed_hash(value, nested_filters)
                              : self.class.new(value).permit(*nested_filters).to_unsafe_h
      else
        value.filter_map { |item| permit_array_item(item, nested_filters) }
      end
    end

    def permit_array_item(item, nested_filters)
      if item.is_a?(Hash)
        nested_filters.empty? ? nil : self.class.new(item).permit(*nested_filters).to_unsafe_h
      else
        nested_filters.empty? ? item : nil
      end
    end

    # A browser form built for `accepts_nested_attributes_for` (via
    # Prism::FormBuilder-style "object[assoc_attributes][0][field]" names)
    # arrives, once Prism::Params.nested_from expands the brackets, as a
    # Hash keyed by the string indices "0", "1", ... - NOT an Array. Left
    # to the plain nested-Hash branch above, `permit` would try to permit
    # "0"/"1" themselves as attribute names against the caller's filter
    # list (:id, :body, ...) and silently drop everything, so
    # `comments_attributes` would always end up `{}` even though the
    # request genuinely carried two comments - exactly the sort of bug that
    # only shows up over a real request cycle, not in a unit test built
    # directly on a Ruby Array. Detecting the all-numeric-key shape lets
    # each entry go through the same per-item allowlist as a real Array,
    # while keeping the original index keys in the result (matching what
    # Model#assign / accepts_nested_attributes_for expects to iterate).
    def indexed_hash?(value)
      !value.empty? && value.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }
    end

    def permit_indexed_hash(value, nested_filters)
      value.each_with_object({}) do |(index, item), acc|
        permitted = permit_array_item(item, nested_filters)
        acc[index] = permitted unless permitted.nil?
      end
    end

    def deep_copy(value)
      case value
      when Hash then value.each_with_object({}) { |(key, val), acc| acc[key] = deep_copy(val) }
      when Array then value.map { |item| deep_copy(item) }
      else value
      end
    end
  end

  class Params
    def require(key)
      StrongParameters.new(self).require(key)
    end

    def permit(*filters)
      StrongParameters.new(self).permit(*filters)
    end
  end
end
