require 'time'

module Facet
  module Orm
    module TypeCasting
      class InvalidCast < StandardError; end

      TRUE_STRINGS = %w[1 t true y yes on].freeze
      FALSE_STRINGS = %w[0 f false n no off].freeze

      module_function

      def cast(type, value)
        return nil if value.nil?

        case type
        when :string, :text then cast_string(value)
        when :integer then cast_integer(value)
        when :float then cast_float(value)
        when :boolean then cast_boolean(value)
        when :datetime then cast_datetime(value)
        else raise ArgumentError, "unknown attribute type #{type.inspect}"
        end
      end

      def cast_string(value)
        value.is_a?(String) ? value : value.to_s
      end

      def cast_integer(value)
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(Numeric)
        str = value.to_s.strip
        return nil if str.empty?
        Integer(str, 10)
      rescue ArgumentError
        raise InvalidCast, "#{value.inspect} is not a valid :integer"
      end

      def cast_float(value)
        return value if value.is_a?(Float)
        return value.to_f if value.is_a?(Numeric)
        str = value.to_s.strip
        return nil if str.empty?
        Float(str)
      rescue ArgumentError
        raise InvalidCast, "#{value.inspect} is not a valid :float"
      end

      def cast_boolean(value)
        return value if value == true || value == false
        token = value.is_a?(String) ? value.strip.downcase : value.to_s
        return true if TRUE_STRINGS.include?(token)
        return false if FALSE_STRINGS.include?(token)
        raise InvalidCast, "#{value.inspect} is not a valid :boolean"
      end

      def cast_datetime(value)
        return value if value.is_a?(Time)
        return value.to_time if value.is_a?(Date) || value.is_a?(DateTime)
        Time.parse(value.to_s)
      rescue ArgumentError
        raise InvalidCast, "#{value.inspect} is not a valid :datetime"
      end
    end
  end
end
