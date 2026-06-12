require 'time'

module Prism
  module Orm
    # ActiveModel::Type-lite: coerces a raw value (almost always a String,
    # since every value that ever crosses an HTTP request - query string,
    # form body, JSON string fields typed as numbers-in-quotes - arrives as
    # one) into the Ruby type an attribute is declared to hold.
    #
    # Kept deliberately separate from Store/Migration's column *names*:
    # a migration's `t.integer :views` has never done anything with the
    # type beyond documenting intent (TableDefinition#column discards it),
    # and this module does not change that. Casting here is opt-in per
    # attribute via `Attributes.attribute` - it does not infer behavior
    # from a migration's declared column type.
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

      # Blank input ("" left in an optional numeric form field) casts to
      # nil rather than 0 - the two mean different things (unknown vs.
      # zero) and collapsing them would silently corrupt any numericality
      # validation or aggregate downstream. Anything non-blank that is not
      # a real integer is a boundary violation (malformed request/API
      # misuse), not a value worth guessing at, so it raises loudly - the
      # same posture this ORM already takes for StaleObjectError/
      # UniqueConstraintViolation rather than swallowing the problem.
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

      # true/false pass through untouched (including from a previously-cast
      # attribute re-read through the getter). Recognized string/integer
      # forms map case-insensitively; anything else raises rather than
      # defaulting to Ruby's "anything non-nil/false is truthy", which
      # would silently turn a typo'd param value into `true`.
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
