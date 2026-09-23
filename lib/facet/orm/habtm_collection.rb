module Facet
  module Orm
    class HabtmCollection
      include Enumerable
      include CollectionSerialization

      def initialize(owner, target:, join_table:, left_key:, right_key:)
        @owner = owner
        @target = target
        @join_table = join_table
        @left_key = left_key
        @right_key = right_key
      end

      def to_a
        ids = target_ids
        ids.empty? ? [] : @target.where(id: ids).to_a
      end

      def each
        return enum_for(:each) unless block_given?
        to_a.each { |record| yield record }
      end

      def ids
        target_ids
      end

      def count
        target_ids.size
      end

      def include?(record)
        target_ids.include?(record.id)
      end

      def <<(record)
        return self if include?(record)
        store.insert(@join_table, @left_key => @owner.id, @right_key => record.id)
        self
      end
      alias_method :push, :<<

      def delete(record)
        row = join_rows.find { |r| r[@right_key] == record.id }
        store.delete(@join_table, row['id']) if row
        self
      end

      def replace(records)
        join_rows.each { |row| store.delete(@join_table, row['id']) }
        records.each { |record| self << record }
        self
      end

      private

      def store
        @owner.class.store
      end

      def join_rows
        store.all(@join_table).select { |row| row[@left_key] == @owner.id }
      end

      def target_ids
        join_rows.map { |row| row[@right_key] }
      end
    end
  end
end
