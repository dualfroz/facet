require 'pstore'
require 'fileutils'

module Prism
  module Orm
    class Store
      class RecordNotFound < StandardError; end
      class UnknownTable < StandardError; end
      class TableExists < StandardError; end

      def initialize(path)
        @path = path
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless directory == '.' || Dir.exist?(directory)
        @pstore = PStore.new(path)
        @in_transaction = false
        transaction { @pstore[:tables] ||= {} }
      end

      def transaction
        within_transaction { yield }
      end

      def create_table(name, columns = [])
        table = name.to_s
        within_transaction do
          raise TableExists, "table #{table} already exists" if @pstore[:tables].key?(table)
          @pstore[:tables][table] = { columns: columns.map(&:to_s), rows: {}, next_id: 1 }
        end
      end

      def drop_table(name)
        within_transaction { @pstore[:tables].delete(name.to_s) }
      end

      def add_column(table, column, default: nil)
        within_transaction do
          definition = table_definition(table)
          column = column.to_s
          next if definition[:columns].include?(column)
          definition[:columns] << column
          definition[:rows].each_value { |row| row[column] = default }
        end
      end

      def remove_column(table, column)
        within_transaction do
          definition = table_definition(table)
          definition[:columns].delete(column.to_s)
          definition[:rows].each_value { |row| row.delete(column.to_s) }
        end
      end

      def table_exists?(table)
        within_transaction(read_only: true) { @pstore[:tables].key?(table.to_s) }
      end

      def columns(table)
        within_transaction(read_only: true) { table_definition(table)[:columns].dup }
      end

      def insert(table, attributes)
        within_transaction do
          definition = table_definition(table)
          id = definition[:next_id]
          definition[:rows][id] = attributes.transform_keys(&:to_s).merge('id' => id)
          definition[:next_id] = id + 1
          id
        end
      end

      def update(table, id, attributes)
        within_transaction do
          row = table_definition(table)[:rows][id.to_i]
          raise RecordNotFound, "no #{table} with id #{id}" unless row
          row.merge!(attributes.transform_keys(&:to_s))
          row.dup
        end
      end

      def delete(table, id)
        within_transaction { table_definition(table)[:rows].delete(id.to_i) }
      end

      def find(table, id)
        within_transaction(read_only: true) { table_definition(table)[:rows][id.to_i]&.dup }
      end

      def all(table)
        within_transaction(read_only: true) { table_definition(table)[:rows].values.map(&:dup) }
      end

      def count(table)
        within_transaction(read_only: true) { table_definition(table)[:rows].size }
      end

      def applied_migrations
        within_transaction(read_only: true) { (@pstore[:schema_migrations] || []).dup }
      end

      def record_migration(version)
        within_transaction do
          @pstore[:schema_migrations] ||= []
          @pstore[:schema_migrations] << version.to_s unless @pstore[:schema_migrations].include?(version.to_s)
        end
      end

      def forget_migration(version)
        within_transaction { (@pstore[:schema_migrations] || []).delete(version.to_s) }
      end

      private

      def within_transaction(read_only: false)
        return yield if @in_transaction

        @pstore.transaction(read_only) do
          @in_transaction = true
          begin
            yield
          ensure
            @in_transaction = false
          end
        end
      end

      def table_definition(table)
        @pstore[:tables].fetch(table.to_s) { raise UnknownTable, "no table #{table}" }
      end
    end
  end
end
