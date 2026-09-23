module Facet
  module Orm
    module Query
      class ConditionNode
        def and(other)
          return other if is_a?(MatchAll)
          return self if other.is_a?(MatchAll)
          AndNode.new(self, other)
        end

        def or(other)
          OrNode.new(self, other)
        end

        def negate
          NotNode.new(self)
        end

        def matches?(_row)
          raise NotImplementedError
        end

        def indexable_equalities
          {}
        end

        def indexable_ranges
          {}
        end

        def indexable_in_lists
          {}
        end

        def indexable_equality_ranges
          equalities = indexable_equalities
          return {} if equalities.empty?

          indexable_ranges.each_with_object({}) do |(column, bounds), acc|
            prefix = equalities.reject { |c, _| c == column }
            acc[column] = { equalities: prefix, bounds: bounds } unless prefix.empty?
          end
        end

        def indexed_candidates(store, table)
          equalities = indexable_equalities
          unless equalities.empty?
            hit = store.lookup_by_index(table, equalities)
            return hit unless hit.nil?
          end

          indexable_in_lists.each do |column, values|
            hit = store.lookup_by_index_in(table, column, values)
            return hit unless hit.nil?
          end

          indexable_equality_ranges.each do |column, spec|
            hit = store.lookup_by_index_equality_range(table, spec[:equalities], column, spec[:bounds])
            return hit unless hit.nil?
          end

          indexable_ranges.each do |column, operators|
            hit = store.lookup_by_index_range(table, column, operators)
            return hit unless hit.nil?
          end

          nil
        end
      end

      class MatchAll < ConditionNode
        def matches?(_row)
          true
        end
      end

      class MatchNone < ConditionNode
        def matches?(_row)
          false
        end
      end

      class HashNode < ConditionNode
        def initialize(conditions, model: nil)
          @conditions = conditions.transform_keys(&:to_s)
          @conditions = cast_enum_values(@conditions, model) if model
          @conditions = cast_encrypted_values(@conditions, model) if model
        end

        def matches?(row)
          @conditions.all? { |key, expected| Predicates.evaluate(row[key], expected) }
        end

        def indexable_equalities
          @conditions.reject { |_key, expected| expected.is_a?(Hash) || expected.is_a?(Array) ||
                                                  expected.is_a?(Range) || expected.is_a?(Regexp) }
        end

        RANGE_OPERATORS = %i[gt gte lt lte].freeze

        def indexable_ranges
          @conditions.each_with_object({}) do |(column, expected), acc|
            bounds = range_bounds_for(expected)
            acc[column] = bounds if bounds
          end
        end

        def indexable_in_lists
          @conditions.each_with_object({}) do |(column, expected), acc|
            acc[column] = expected if expected.is_a?(Array)
          end
        end

        private

        def range_bounds_for(expected)
          case expected
          when Hash
            bounds = expected.each_with_object({}) { |(op, value), h| h[op.to_sym] = value }
            bounds.empty? || !bounds.keys.all? { |op| RANGE_OPERATORS.include?(op) } ? nil : bounds
          when Range
            bounds = {}
            bounds[:gte] = expected.begin unless expected.begin.nil?
            bounds[expected.exclude_end? ? :lt : :lte] = expected.end unless expected.end.nil?
            bounds.empty? ? nil : bounds
          end
        end

        def cast_enum_values(conditions, model)
          return conditions unless model.respond_to?(:enum_definitions)
          enums = model.enum_definitions
          return conditions if enums.empty?

          conditions.each_with_object({}) do |(column, value), acc|
            acc[column] = enums.key?(column) ? cast_value(model, column, value) : value
          end
        end

        def cast_value(model, column, value)
          case value
          when Array then value.map { |item| model.enum_cast(column, item) }
          when Hash then cast_operator_hash(model, column, value)
          when Range, Regexp then value
          else model.enum_cast(column, value)
          end
        end

        def cast_operator_hash(model, column, operators)
          operators.each_with_object({}) do |(operator, value), acc|
            acc[operator] = if operator.to_sym == :is_null
              value
            elsif value.is_a?(Array)
              value.map { |item| model.enum_cast(column, item) }
            else
              model.enum_cast(column, value)
            end
          end
        end

        def cast_encrypted_values(conditions, model)
          return conditions unless model.respond_to?(:encrypted_attributes)
          encrypted = model.encrypted_attributes
          return conditions if encrypted.empty?

          conditions.each_with_object({}) do |(column, value), acc|
            acc[column] = encrypted.key?(column) ? cast_encrypted_value(model, column, value) : value
          end
        end

        def cast_encrypted_value(model, column, value)
          case value
          when Array then value.flat_map { |item| Array(model.encrypt_for_query(column, item)) }
          when Hash then cast_encrypted_operator_hash(model, column, value)
          when Range, Regexp then value
          else model.encrypt_for_query(column, value)
          end
        end

        def cast_encrypted_operator_hash(model, column, operators)
          operators.each_with_object({}) do |(operator, value), acc|
            acc[operator] = if operator.to_sym == :is_null
              value
            elsif value.is_a?(Array)
              value.flat_map { |item| Array(model.encrypt_for_query(column, item)) }
            else
              model.encrypt_for_query(column, value)
            end
          end
        end
      end

      class AndNode < ConditionNode
        def initialize(left, right)
          @left = left
          @right = right
        end

        def matches?(row)
          @left.matches?(row) && @right.matches?(row)
        end

        def indexable_equalities
          @left.indexable_equalities.merge(@right.indexable_equalities)
        end

        def indexable_ranges
          left = @left.indexable_ranges
          right = @right.indexable_ranges
          (left.keys | right.keys).each_with_object({}) do |column, acc|
            acc[column] = (left[column] || {}).merge(right[column] || {})
          end
        end

        def indexable_in_lists
          left = @left.indexable_in_lists
          right = @right.indexable_in_lists
          (left.keys | right.keys).each_with_object({}) do |column, acc|
            acc[column] = if left.key?(column) && right.key?(column)
                             left[column] & right[column]
                           else
                             left[column] || right[column]
                           end
          end
        end
      end

      class OrNode < ConditionNode
        def initialize(left, right)
          @left = left
          @right = right
        end

        def matches?(row)
          @left.matches?(row) || @right.matches?(row)
        end

        def indexed_candidates(store, table)
          left_hit = @left.indexed_candidates(store, table)
          return nil if left_hit.nil?

          right_hit = @right.indexed_candidates(store, table)
          return nil if right_hit.nil?

          (left_hit + right_hit).uniq { |row| row['id'] }
        end
      end

      class NotNode < ConditionNode
        def initialize(node)
          @node = node
        end

        def matches?(row)
          !@node.matches?(row)
        end
      end
    end
  end
end
