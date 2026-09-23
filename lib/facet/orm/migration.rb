module Facet
  module Orm
    class Migration
      class TableDefinition
        attr_reader :columns, :indexes

        def initialize
          @columns = ['id']
          @indexes = []
        end

        def column(name, _type = :string)
          @columns << name.to_s
        end

        %i[string text integer float boolean datetime].each do |type|
          define_method(type) { |name| column(name, type) }
        end

        def timestamps
          column(:created_at)
          column(:updated_at)
        end

        def index(columns, unique: false, name: nil)
          @indexes << { columns: Array(columns), unique: unique, name: name }
        end
      end

      def initialize(store)
        @store = store
      end

      def up
        raise NotImplementedError, "#{self.class} must implement #up"
      end

      def down
        raise NotImplementedError, "#{self.class} must implement #down"
      end

      private

      attr_reader :store

      def create_table(name)
        definition = TableDefinition.new
        yield(definition) if block_given?
        store.create_table(name, definition.columns)
        definition.indexes.each do |index|
          store.add_index(name, index[:columns], unique: index[:unique], name: index[:name])
        end
      end

      def drop_table(name)
        store.drop_table(name)
      end

      def add_column(table, column, _type = :string, default: nil)
        store.add_column(table, column, default: default)
      end

      def remove_column(table, column)
        store.remove_column(table, column)
      end

      def add_index(table, columns, unique: false, name: nil)
        store.add_index(table, columns, unique: unique, name: name)
      end

      def remove_index(table, columns_or_name)
        store.remove_index(table, columns_or_name)
      end
    end
  end
end
