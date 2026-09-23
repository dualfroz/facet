require 'pstore'
require 'fileutils'

module Facet
  module Orm
    class Store
      class RecordNotFound < StandardError; end
      class UnknownTable < StandardError; end
      class TableExists < StandardError; end
      class StaleRowError < StandardError; end
      class IndexExists < StandardError; end
      class UnknownIndex < StandardError; end
      class UniqueConstraintViolation < StandardError; end

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

      def transaction_registry
        @transaction_registry ||= TransactionRegistry.new
      end

      def transaction_with_callbacks(requires_new: false, &block)
        if requires_new && transaction_registry.nested?
          within_transaction { transaction_registry.within_savepoint(self, &block) }
        else
          transaction_registry.within { transaction(&block) }
        end
      end

      def snapshot_tables
        Marshal.load(Marshal.dump(@pstore[:tables]))
      end

      def restore_tables(snapshot)
        @pstore[:tables] = snapshot
      end

      def create_table(name, columns = [])
        table = name.to_s
        within_transaction do
          raise TableExists, "table #{table} already exists" if @pstore[:tables].key?(table)
          @pstore[:tables][table] = { columns: columns.map(&:to_s), rows: {}, next_id: 1, defaults: {}, indexes: {} }
        end
      end

      def drop_table(name)
        within_transaction { @pstore[:tables].delete(name.to_s) }
      end

      def add_column(table, column, default: nil)
        within_transaction do
          definition = table_definition(table)
          column = column.to_s
          definition[:defaults] ||= {}
          definition[:defaults][column] = default unless default.nil?
          next if definition[:columns].include?(column)
          definition[:columns] << column
          definition[:rows].each_value { |row| row[column] = default }
          rebuild_indexes_covering(definition, column)
        end
      end

      def remove_column(table, column)
        within_transaction do
          definition = table_definition(table)
          column = column.to_s
          definition[:columns].delete(column)
          definition[:rows].each_value { |row| row.delete(column) }
          (definition[:defaults] ||= {}).delete(column)
          (definition[:indexes] ||= {}).reject! { |_name, index| index[:columns].include?(column) }
        end
      end

      def table_exists?(table)
        within_transaction(read_only: true) { @pstore[:tables].key?(table.to_s) }
      end

      def columns(table)
        within_transaction(read_only: true) { table_definition(table)[:columns].dup }
      end

      def insert(table, attributes)
        instrument('INSERT', table) do
          within_transaction do
            definition = table_definition(table)
            id = definition[:next_id]
            row = attributes.transform_keys(&:to_s)
            (definition[:defaults] || {}).each { |column, default| row[column] = default unless row.key?(column) }
            row['id'] = id
            validate_unique_indexes(definition, id, row)
            index_add(definition, id, row)
            definition[:rows][id] = row
            definition[:next_id] = id + 1
            id
          end
        end
      end

      def update(table, id, attributes, lock = nil)
        instrument('UPDATE', table, id: id) do
          within_transaction do
            definition = table_definition(table)
            row = definition[:rows][id.to_i]
            raise RecordNotFound, "no #{table} with id #{id}" unless row
            attributes = attributes.transform_keys(&:to_s)
            if lock
              lock_column, lock_version = lock
              actual = row[lock_column].to_i
              unless actual == lock_version.to_i
                raise StaleRowError, "expected #{table}##{id} #{lock_column}=#{lock_version}, found #{actual}"
              end
              attributes = attributes.merge(lock_column => actual + 1)
            end
            new_row = row.merge(attributes)
            validate_unique_indexes(definition, id.to_i, new_row)
            index_remove(definition, id.to_i, row)
            index_add(definition, id.to_i, new_row)
            row.merge!(attributes)
            row.dup
          end
        end
      end

      def increment_counter(table, id, column, by = 1)
        instrument('UPDATE', table, id: id) do
          within_transaction do
            row = table_definition(table)[:rows][id.to_i]
            raise RecordNotFound, "no #{table} with id #{id}" unless row
            column = column.to_s
            row[column] = row[column].to_i + by
            row.dup
          end
        end
      end

      def delete(table, id, lock = nil)
        instrument('DELETE', table, id: id) do
          within_transaction do
            definition = table_definition(table)
            row = definition[:rows][id.to_i]
            if lock
              lock_column, lock_version = lock
              raise RecordNotFound, "no #{table} with id #{id}" unless row
              actual = row[lock_column].to_i
              unless actual == lock_version.to_i
                raise StaleRowError, "expected #{table}##{id} #{lock_column}=#{lock_version}, found #{actual}"
              end
            end
            index_remove(definition, id.to_i, row) if row
            definition[:rows].delete(id.to_i)
          end
        end
      end

      def find(table, id)
        instrument('SELECT', table, id: id) do
          within_transaction(read_only: true) { table_definition(table)[:rows][id.to_i]&.dup }
        end
      end

      def all(table)
        instrument('SELECT', table) do
          within_transaction(read_only: true) { table_definition(table)[:rows].values.map(&:dup) }
        end
      end

      def count(table)
        instrument('SELECT COUNT', table) do
          within_transaction(read_only: true) { table_definition(table)[:rows].size }
        end
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

      def add_index(table, columns, unique: false, name: nil)
        within_transaction do
          definition = table_definition(table)
          columns = Array(columns).map(&:to_s)
          index_name = (name || "index_#{table}_on_#{columns.join('_and_')}").to_s
          definition[:indexes] ||= {}
          raise IndexExists, "index #{index_name} already exists on #{table}" if definition[:indexes].key?(index_name)

          definition[:indexes][index_name] =
            build_index_data(definition, columns, unique: unique, name: index_name)
          index_name
        end
      end

      def remove_index(table, name_or_columns)
        within_transaction do
          definition = table_definition(table)
          definition[:indexes] ||= {}
          index_name = resolve_index_name(definition, name_or_columns)
          raise UnknownIndex, "no index #{name_or_columns.inspect} on #{table}" unless index_name
          definition[:indexes].delete(index_name)
        end
      end

      def indexes(table)
        within_transaction(read_only: true) do
          (table_definition(table)[:indexes] || {}).values.map do |index|
            { name: index[:name], columns: index[:columns].dup, unique: index[:unique] }
          end
        end
      end

      def lookup_by_index(table, equalities)
        return nil if equalities.empty?

        if equalities.key?('id')
          return instrument('SELECT INDEX', table, columns: ['id']) do
            rows_by_id(table, [equalities['id']])
          end
        end

        available = within_transaction(read_only: true) do
          (table_definition(table)[:indexes] || {}).values
        end
        index = available.select { |candidate| candidate[:columns].all? { |c| equalities.key?(c) } }
                          .max_by { |candidate| candidate[:columns].size }
        return nil unless index

        instrument('SELECT INDEX', table, columns: index[:columns]) do
          within_transaction(read_only: true) do
            definition = table_definition(table)
            key = index[:columns].map { |column| equalities[column] }
            ids = (table_definition(table)[:indexes][index[:name]][:map][key] || [])
            ids.map { |id| definition[:rows][id]&.dup }.compact
          end
        end
      end

      def lookup_by_index_range(table, column, operators)
        column = column.to_s
        index = within_transaction(read_only: true) do
          (table_definition(table)[:indexes] || {}).values
            .find { |candidate| candidate[:range_capable] && candidate[:columns] == [column] }
        end
        return nil unless index

        instrument('SELECT INDEX RANGE', table, columns: index[:columns]) do
          within_transaction(read_only: true) do
            definition = table_definition(table)
            sorted = definition[:indexes][index[:name]][:sorted_values]
            lo, hi = range_bounds(sorted, operators)
            ids = sorted[lo...hi].flat_map { |value| definition[:indexes][index[:name]][:map][[value]] || [] }
            ids.uniq.map { |id| definition[:rows][id]&.dup }.compact
          end
        end
      end

      def lookup_by_index_equality_range(table, equalities, range_column, operators)
        equalities = equalities.transform_keys(&:to_s)
        range_column = range_column.to_s

        index = within_transaction(read_only: true) do
          (table_definition(table)[:indexes] || {}).values
            .select do |candidate|
              candidate[:composite_range_capable] &&
                candidate[:columns].last == range_column &&
                candidate[:columns][0..-2].all? { |column| equalities.key?(column) }
            end
            .max_by { |candidate| candidate[:columns].size }
        end
        return nil unless index

        instrument('SELECT INDEX RANGE', table, columns: index[:columns]) do
          within_transaction(read_only: true) do
            definition = table_definition(table)
            prefix_key = index[:columns][0..-2].map { |column| equalities[column] }
            sorted = definition[:indexes][index[:name]][:sorted_by_prefix][prefix_key] || []
            lo, hi = range_bounds(sorted, operators)
            ids = sorted[lo...hi].flat_map do |value|
              definition[:indexes][index[:name]][:map][prefix_key + [value]] || []
            end
            ids.uniq.map { |id| definition[:rows][id]&.dup }.compact
          end
        end
      end

      def lookup_by_index_in(table, column, values)
        column = column.to_s
        values = values.uniq

        if column == 'id'
          instrument('SELECT INDEX IN', table, columns: ['id']) do
            rows_by_id(table, values)
          end
        else
          index = within_transaction(read_only: true) do
            (table_definition(table)[:indexes] || {}).values.find { |candidate| candidate[:columns] == [column] }
          end
          return nil unless index

          instrument('SELECT INDEX IN', table, columns: index[:columns]) do
            within_transaction(read_only: true) do
              definition = table_definition(table)
              ids = values.flat_map { |value| definition[:indexes][index[:name]][:map][[value]] || [] }
              ids.uniq.map { |id| definition[:rows][id]&.dup }.compact
            end
          end
        end
      end

      private

      def rows_by_id(table, ids)
        within_transaction(read_only: true) do
          rows = table_definition(table)[:rows]
          ids.map { |id| rows[id.to_i]&.dup }.compact
        end
      end

      def range_bounds(sorted, operators)
        lo = 0
        hi = sorted.length
        if operators.key?(:gte)
          lo = sorted.bsearch_index { |v| v >= operators[:gte] } || sorted.length
        elsif operators.key?(:gt)
          lo = sorted.bsearch_index { |v| v > operators[:gt] } || sorted.length
        end
        if operators.key?(:lte)
          hi = sorted.bsearch_index { |v| v > operators[:lte] } || sorted.length
        elsif operators.key?(:lt)
          hi = sorted.bsearch_index { |v| v >= operators[:lt] } || sorted.length
        end
        [lo, hi]
      end

      def resolve_index_name(definition, name_or_columns)
        return name_or_columns.to_s if definition[:indexes].key?(name_or_columns.to_s)
        columns = Array(name_or_columns).map(&:to_s)
        match = definition[:indexes].values.find { |index| index[:columns] == columns }
        match && match[:name]
      end

      def build_index_data(definition, columns, unique:, name:)
        map = {}
        definition[:rows].each do |id, row|
          key = columns.map { |column| row[column] }
          existing = (map[key] ||= [])
          if unique && !existing.empty?
            raise UniqueConstraintViolation,
                  "cannot create unique index #{name}: duplicate value for #{columns.join(', ')}"
          end
          existing << id
        end

        range_capable = false
        sorted_values = []
        if columns.size == 1
          begin
            sorted_values = map.keys.map(&:first).compact.sort
            range_capable = true
          rescue ArgumentError, TypeError
            range_capable = false
            sorted_values = []
          end
        end

        composite_range_capable = false
        sorted_by_prefix = {}
        if columns.size > 1
          begin
            grouped = Hash.new { |hash, key| hash[key] = [] }
            map.each_key { |key| grouped[key[0..-2]] << key.last }
            grouped.each { |prefix, values| sorted_by_prefix[prefix] = values.compact.uniq.sort }
            composite_range_capable = true
          rescue ArgumentError, TypeError
            composite_range_capable = false
            sorted_by_prefix = {}
          end
        end

        { name: name, columns: columns, unique: !!unique, map: map,
          range_capable: range_capable, sorted_values: sorted_values,
          composite_range_capable: composite_range_capable, sorted_by_prefix: sorted_by_prefix }
      end

      def rebuild_indexes_covering(definition, column)
        (definition[:indexes] || {}).each do |name, index|
          next unless index[:columns].include?(column)
          definition[:indexes][name] = build_index_data(definition, index[:columns], unique: index[:unique], name: name)
        end
      end

      def validate_unique_indexes(definition, id, row)
        (definition[:indexes] || {}).each_value do |index|
          next unless index[:unique]
          key = index[:columns].map { |column| row[column] }
          existing = index[:map][key]
          next if existing.nil? || existing.empty? || existing == [id]
          raise UniqueConstraintViolation,
                "duplicate value for unique index #{index[:name]} on #{index[:columns].join(', ')}"
        end
      end

      def index_add(definition, id, row)
        (definition[:indexes] || {}).each_value do |index|
          key = index[:columns].map { |column| row[column] }
          is_new_key = !index[:map].key?(key) || index[:map][key].empty?
          list = (index[:map][key] ||= [])
          list << id unless list.include?(id)
          insert_sorted_value(index, key.first) if is_new_key && index[:range_capable] && !key.first.nil?
          insert_sorted_prefix_value(index, key) if is_new_key && index[:composite_range_capable] && !key.last.nil?
        end
      end

      def index_remove(definition, id, row)
        (definition[:indexes] || {}).each_value do |index|
          key = index[:columns].map { |column| row[column] }
          list = index[:map][key]
          next unless list
          list.delete(id)
          next unless list.empty?
          index[:map].delete(key)
          remove_sorted_value(index, key.first) if index[:range_capable] && !key.first.nil?
          remove_sorted_prefix_value(index, key) if index[:composite_range_capable] && !key.last.nil?
        end
      end

      def insert_sorted_value(index, value)
        sorted = index[:sorted_values]
        idx = sorted.bsearch_index { |v| v >= value } || sorted.length
        sorted.insert(idx, value) unless sorted[idx] == value
      rescue ArgumentError
        index[:range_capable] = false
        index[:sorted_values] = []
      end

      def remove_sorted_value(index, value)
        sorted = index[:sorted_values]
        idx = sorted.bsearch_index { |v| v >= value }
        sorted.delete_at(idx) if idx && sorted[idx] == value
      rescue ArgumentError
        index[:range_capable] = false
        index[:sorted_values] = []
      end

      def insert_sorted_prefix_value(index, key)
        prefix, value = key[0..-2], key.last
        sorted = (index[:sorted_by_prefix][prefix] ||= [])
        idx = sorted.bsearch_index { |v| v >= value } || sorted.length
        sorted.insert(idx, value) unless sorted[idx] == value
      rescue ArgumentError
        index[:composite_range_capable] = false
        index[:sorted_by_prefix] = {}
      end

      def remove_sorted_prefix_value(index, key)
        prefix, value = key[0..-2], key.last
        sorted = index[:sorted_by_prefix][prefix]
        return unless sorted
        idx = sorted.bsearch_index { |v| v >= value }
        sorted.delete_at(idx) if idx && sorted[idx] == value
        index[:sorted_by_prefix].delete(prefix) if sorted.empty?
      rescue ArgumentError
        index[:composite_range_capable] = false
        index[:sorted_by_prefix] = {}
      end

      def instrument(operation, table, extra = {})
        Instrumentation.instrument('sql.facet', { operation: operation, table: table.to_s }.merge(extra)) do
          yield
        end
      end

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
