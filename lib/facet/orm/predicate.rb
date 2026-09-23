require 'facet'

module Facet
  module Orm
    class Predicate
      OPERATORS = %i[
        eq not_eq gt gteq lt lteq in not_in between
        matches does_not_match starts_with ends_with is_null is_not_null
      ].freeze

      ALIASES = { ne: :not_eq, gte: :gteq, lte: :lteq, like: :matches, unlike: :does_not_match }.freeze

      attr_reader :operator, :argument

      def initialize(operator, argument = nil)
        @operator = operator.to_sym
        @argument = argument
      end

      class << self
        def parse(value)
          case value
          when Predicate then [value]
          when nil then [new(:is_null)]
          when Range then [new(:between, value)]
          when Array then [new(:in, value)]
          when Hash then value.map { |operator, argument| from_pair(operator, argument) }
          else [new(:eq, value)]
          end
        end

        def from_pair(operator, argument)
          canonical = ALIASES.fetch(operator.to_sym, operator.to_sym)
          raise ArgumentError, "unknown predicate operator #{operator}" unless OPERATORS.include?(canonical)
          if %i[is_null is_not_null].include?(canonical)
            argument == false ? new(canonical == :is_null ? :is_not_null : :is_null) : new(canonical)
          else
            new(canonical, argument)
          end
        end

        %i[eq not_eq gt gteq lt lteq between matches does_not_match starts_with ends_with].each do |operator|
          define_method(operator) { |argument| new(operator, argument) }
        end

        define_method(:in) { |argument| new(:in, argument) }
        define_method(:not_in) { |argument| new(:not_in, argument) }
        define_method(:is_null) { new(:is_null) }
        define_method(:is_not_null) { new(:is_not_null) }
      end

      def matches_row?(row, column)
        matches_value?(row[column.to_s])
      end

      def matches_value?(actual)
        case @operator
        when :eq then actual == @argument
        when :not_eq then actual != @argument
        when :gt then comparison(actual) == 1
        when :gteq then [0, 1].include?(comparison(actual))
        when :lt then comparison(actual) == -1
        when :lteq then [0, -1].include?(comparison(actual))
        when :in then contained?(actual)
        when :not_in then !contained?(actual)
        when :between then !actual.nil? && @argument.cover?(actual)
        when :matches then !actual.nil? && like_regex(@argument).match?(actual.to_s)
        when :does_not_match then actual.nil? || !like_regex(@argument).match?(actual.to_s)
        when :starts_with then !actual.nil? && actual.to_s.start_with?(@argument.to_s)
        when :ends_with then !actual.nil? && actual.to_s.end_with?(@argument.to_s)
        when :is_null then actual.nil?
        when :is_not_null then !actual.nil?
        end
      end

      def ==(other)
        other.is_a?(Predicate) && other.operator == @operator && other.argument == @argument
      end

      def inspect
        "#<Predicate #{@operator} #{@argument.inspect}>"
      end

      private

      def comparison(actual)
        return nil if actual.nil?
        actual <=> @argument
      end

      def contained?(actual)
        if @argument.is_a?(Range)
          @argument.cover?(actual)
        else
          @argument.include?(actual)
        end
      end

      def like_regex(pattern)
        source = +'\A'
        pattern.to_s.each_char do |character|
          case character
          when '%' then source << '.*'
          when '_' then source << '.'
          else source << Regexp.escape(character)
          end
        end
        source << '\z'
        Regexp.new(source)
      end
    end
  end
end
