module Prism
  module Orm
    class Relation
      include Enumerable
      include Pagination
      include CollectionSerialization

      attr_reader :condition

      def initialize(model, condition: Query::MatchAll.new, order_by: nil, limit_value: nil,
                     offset_value: nil, distinct_value: false, includes_value: [],
                     page_value: nil, per_page_value: nil)
        @model = model
        @condition = condition
        @order_by = order_by
        @limit_value = limit_value
        @offset_value = offset_value
        @distinct_value = distinct_value
        @includes_value = includes_value
        @page_value = page_value
        @per_page_value = per_page_value
      end

      def includes(*names)
        spawn(includes_value: @includes_value + names.flatten.map(&:to_sym))
      end

      def where(conditions)
        spawn(condition: @condition.and(Query::HashNode.new(conditions, model: @model)))
      end

      def not(conditions)
        spawn(condition: @condition.and(Query::HashNode.new(conditions, model: @model).negate))
      end

      def or(other)
        other_condition = other.is_a?(Relation) ? other.condition : Query::HashNode.new(other, model: @model)
        spawn(condition: @condition.or(other_condition))
      end

      def none
        spawn(condition: Query::MatchNone.new)
      end

      def order(column, direction = :asc)
        spawn(order_by: [column.to_s, direction.to_sym])
      end
      alias_method :reorder, :order

      def limit(count)
        spawn(limit_value: count)
      end

      def offset(count)
        spawn(offset_value: count)
      end

      def distinct
        spawn(distinct_value: true)
      end

      def find_by(conditions)
        where(conditions).first
      end

      def find_by!(conditions)
        find_by(conditions) || raise(RecordNotFound, "no #{@model.name} matching #{conditions.inspect}")
      end

      def each
        return enum_for(:each) unless block_given?
        to_a.each { |record| yield record }
      end

      def to_a
        records = rows.map { |row| @model.instantiate(row) }
        preload(records)
        records
      end

      def count
        rows.size
      end

      def exists?
        !rows.empty?
      end

      def first(count = nil)
        count ? to_a.first(count) : to_a.first
      end

      def first!
        first || raise(RecordNotFound, "no #{@model.name} found")
      end

      def last(count = nil)
        count ? to_a.last(count) : to_a.last
      end

      def last!
        last || raise(RecordNotFound, "no #{@model.name} found")
      end

      def pluck(attribute)
        key = attribute.to_s
        values = rows.map { |row| row[key] }
        @distinct_value ? values.uniq : values
      end

      def pick(*attributes)
        row = rows.first
        return nil unless row
        keys = attributes.map(&:to_s)
        keys.size == 1 ? row[keys.first] : keys.map { |key| row[key] }
      end

      def ids
        pluck('id')
      end

      def sum(column)
        numeric_values(column).sum
      end

      def average(column)
        values = numeric_values(column)
        return nil if values.empty?
        values.sum.to_f / values.size
      end
      alias_method :avg, :average

      def minimum(column)
        numeric_values(column).min
      end
      alias_method :min_of, :minimum

      def maximum(column)
        numeric_values(column).max
      end
      alias_method :max_of, :maximum

      def group(column)
        key = column.to_s
        to_a.group_by { |record| record[key] }
      end

      def group_count(column)
        key = column.to_s
        rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[key]] += 1 }
      end

      def find_each(batch_size: 1000)
        return enum_for(:find_each, batch_size: batch_size) unless block_given?
        find_in_batches(batch_size: batch_size) { |batch| batch.each { |record| yield record } }
      end

      def find_in_batches(batch_size: 1000)
        return enum_for(:find_in_batches, batch_size: batch_size) unless block_given?
        to_a.each_slice(batch_size) { |batch| yield batch }
      end

      def respond_to_missing?(name, include_private = false)
        model_scopes.key?(name) || super
      end

      def method_missing(name, *args, &block)
        body = model_scopes[name]
        return super unless body
        instance_exec(*args, &body)
      end

      private

      def model_scopes
        @model.respond_to?(:scopes) ? @model.scopes : {}
      end

      def numeric_values(column)
        pluck(column).compact
      end

      def spawn(overrides)
        self.class.new(
          @model,
          condition: overrides.fetch(:condition, @condition),
          order_by: overrides.fetch(:order_by, @order_by),
          limit_value: overrides.fetch(:limit_value, @limit_value),
          offset_value: overrides.fetch(:offset_value, @offset_value),
          distinct_value: overrides.fetch(:distinct_value, @distinct_value),
          includes_value: overrides.fetch(:includes_value, @includes_value),
          page_value: overrides.fetch(:page_value, @page_value),
          per_page_value: overrides.fetch(:per_page_value, @per_page_value)
        )
      end

      def rows
        filtered = @model.store.all(@model.table_name).select { |row| matches?(row) }
        filtered = apply_order(filtered)
        filtered = filtered.drop(@offset_value) if @offset_value
        filtered = filtered.first(@limit_value) if @limit_value
        filtered
      end

      def matches?(row)
        @conditions.all? do |key, expected|
          actual = row[key.to_s]
          case expected
          when Range then expected.cover?(actual)
          when Array then expected.include?(actual)
          else actual == expected
          end
        end
      end

      def apply_order(rows)
        return rows unless @order_by
        column, direction = @order_by
        sorted = rows.sort_by { |row| row[column] }
        direction == :desc ? sorted.reverse : sorted
      end
    end
  end
end
