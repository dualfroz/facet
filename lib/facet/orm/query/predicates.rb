module Facet
  module Orm
    module Query
      module Predicates
        OPERATORS = {
          eq: ->(actual, expected) { actual == expected },
          ne: ->(actual, expected) { actual != expected },
          gt: ->(actual, expected) { !actual.nil? && actual > expected },
          gte: ->(actual, expected) { !actual.nil? && actual >= expected },
          lt: ->(actual, expected) { !actual.nil? && actual < expected },
          lte: ->(actual, expected) { !actual.nil? && actual <= expected },
          in: ->(actual, expected) { Array(expected).include?(actual) },
          not_in: ->(actual, expected) { !Array(expected).include?(actual) },
          like: ->(actual, expected) { !actual.nil? && like_match?(actual, expected) },
          not_like: ->(actual, expected) { !actual.nil? && !like_match?(actual, expected) }
        }.freeze

        class UnknownOperator < StandardError; end

        def self.like_match?(actual, pattern)
          source = '\A' + Regexp.escape(pattern.to_s).gsub('%', '.*').gsub('_', '.') + '\z'
          actual.to_s.match?(Regexp.new(source, Regexp::IGNORECASE))
        end

        def self.evaluate(actual, expected)
          case expected
          when Hash
            expected.all? { |operator, value| evaluate_operator(actual, operator, value) }
          when Range
            expected.cover?(actual)
          when Regexp
            !actual.nil? && actual.to_s.match?(expected)
          when Array
            expected.include?(actual)
          else
            actual == expected
          end
        end

        def self.evaluate_operator(actual, operator, value)
          operator = operator.to_sym
          return value ? actual.nil? : !actual.nil? if operator == :is_null

          fn = OPERATORS[operator]
          raise UnknownOperator, "unknown query operator #{operator.inspect}" unless fn
          fn.call(actual, value)
        end
      end
    end
  end
end
