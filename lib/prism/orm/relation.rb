module Prism
  module Orm
    class Relation
      include Enumerable

      def initialize(model, conditions: {}, order_by: nil, limit_value: nil, offset_value: nil)
        @model = model
        @conditions = conditions
        @order_by = order_by
        @limit_value = limit_value
        @offset_value = offset_value
      end

      def where(conditions)
        spawn(conditions: @conditions.merge(conditions.transform_keys(&:to_s)))
      end

      def order(column, direction = :asc)
        spawn(order_by: [column.to_s, direction.to_sym])
      end

      def limit(count)
        spawn(limit_value: count)
      end

      def offset(count)
        spawn(offset_value: count)
      end

      def find_by(conditions)
        where(conditions).first
      end

      def each
        return enum_for(:each) unless block_given?
        rows.each { |row| yield @model.instantiate(row) }
      end

      def to_a
        rows.map { |row| @model.instantiate(row) }
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

      def last(count = nil)
        count ? to_a.last(count) : to_a.last
      end

      def pluck(attribute)
        key = attribute.to_s
        rows.map { |row| row[key] }
      end

      private

      def spawn(overrides)
        self.class.new(
          @model,
          conditions: overrides.fetch(:conditions, @conditions),
          order_by: overrides.fetch(:order_by, @order_by),
          limit_value: overrides.fetch(:limit_value, @limit_value),
          offset_value: overrides.fetch(:offset_value, @offset_value)
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
