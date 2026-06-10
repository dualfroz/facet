require 'pstore'
require 'fileutils'

module Prism
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

      # Wraps `transaction` with participant bookkeeping so after_commit/
      # after_rollback fire exactly once, only for the outermost caller -
      # this is what Model#transaction and Orm.transaction both call.
      #
      # `requires_new: true` opens a real SAVEPOINT instead of flattening
      # into the surrounding transaction (the default, see TransactionRegistry
      # docs): a raise from inside rolls back only the writes made since this
      # call, while the outer transaction keeps whatever it had before and is
      # still free to commit normally afterwards. Asking for requires_new
      # with no surrounding `transaction` block open is just a plain
      # transaction - there is nothing to nest a savepoint inside.
      def transaction_with_callbacks(requires_new: false, &block)
        if requires_new && transaction_registry.nested?
          within_transaction { transaction_registry.within_savepoint(self, &block) }
        else
          transaction_registry.within { transaction(&block) }
        end
      end

      # Deep-copies the current table data so a SAVEPOINT rollback can
      # restore exactly this state later. Must run inside an open
      # transaction (PStore raises otherwise) - callers only reach this via
      # transaction_with_callbacks, which already guarantees that.
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

      # A non-nil `default:` is remembered on the table definition (not just
      # backfilled onto rows that already exist) so it also applies to every
      # row inserted afterwards, the same way a real DB column default
      # would - without this, a column added with `default: 0` reads back
      # as nil, not 0, on any record created after the migration ran.
      #
      # Any existing index that covers this column is rebuilt from the
      # backfilled rows. Without this, an index built while the column was
      # still absent (every row keyed under nil) would stay stuck on that
      # stale map forever - #lookup_by_index would report zero matches for
      # the new default value even though every row now actually has it,
      # which #indexed_candidates trusts as a definitive empty result
      # (see Relation#rows) instead of falling back to a full scan.
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

      # Cascades to any index that covers the removed column, the same way a
      # real database drops an index when the column it is built on is
      # dropped. Leaving such an index in place would be strictly worse than
      # having no index at all: its map/sorted_values would keep referencing
      # a column no longer present on any row, and it would keep matching
      # future #add_index/#lookup_by_index calls by column name alone.
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

      # `lock` (a two-element [column, expected_version] array, or nil to skip
      # the check entirely) implements optimistic locking: the version check
      # and the increment happen inside the same transaction as the merge, so
      # a concurrent writer racing on this exact row can never both succeed
      # against the same lock_version - the loser gets StaleRowError. It is a
      # trailing positional argument rather than keyword arguments on purpose:
      # every existing call site passes `attributes` as a bare trailing hash
      # (`store.update(:users, id, role: 'owner')`), and Ruby 3 would swallow
      # that hash as keyword arguments instead of the `attributes` positional
      # the moment this method declared any keywords of its own, breaking
      # every one of them with a bogus arity error.
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

      # Atomic read-then-write increment/decrement of a single numeric
      # column, used by belongs_to counter_cache instead of a full
      # Model#update - no timestamps bumped, no callbacks/validations run,
      # matching the raw-SQL UPDATE Rails issues for the same feature. Runs
      # inside the surrounding transaction (reentrant via within_transaction)
      # so a counter bump from a child's after_create/after_destroy rolls
      # back together with the child write that triggered it.
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

      # Builds a secondary index over `columns` (one column, or several for a
      # composite index) so `Relation#where` equality lookups on those exact
      # columns can fetch matching rows directly instead of scanning the
      # whole table (see Relation#rows/#indexed_candidates). Backfills from
      # every existing row, the same way a real database builds an index at
      # CREATE INDEX time - not lazily on first query.
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

      # Returns matching row dups for an exact-match lookup on the best
      # available index covering every key in `equalities` (all columns of
      # some index must be present), or nil if no such index exists - the
      # signal for the caller to fall back to a full table scan.
      def lookup_by_index(table, equalities)
        return nil if equalities.empty?

        # `id` is always "indexed" for free - `definition[:rows]` is already
        # a Hash keyed by id, exactly the same reasoning #lookup_by_index_in
        # already applies to an IN-list of ids. Before this, only the
        # IN-list path got that fast lookup; a plain single-id equality
        # (`find_by(id: x)`, `where(id: x).first`, and therefore every
        # Authenticatable#current_user call on every authenticated request)
        # fell all the way through to a registered-index search that could
        # never find one (no framework code ever calls `add_index(table,
        # :id)`) and landed on a full table scan instead - silently, since
        # nothing about that path looked like an error. Any other equality
        # keys alongside `id` are still safe to ignore here: at most one row
        # can ever match on id anyway, and Relation#rows always re-applies
        # the full condition afterward.
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

      # Returns matching row dups for a gt/gte/lt/lte range on the best
      # available range-capable index covering `column` (single-column
      # indexes only), or nil if none exists - the same "nil means scan"
      # contract as #lookup_by_index. `operators` is a Hash of Symbol
      # operator => bound, e.g. { gte: 18, lt: 65 }. Finds the boundary with
      # a binary search over the index's ascending sorted_values (O(log n)),
      # then only touches the ids for values inside those bounds - never a
      # scan of the full distinct-value list, let alone the whole table.
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

      # Returns matching row dups for an equality-prefix-plus-range lookup
      # (`where(scope: val, position: { lt: x })`) on the best available
      # composite index whose own columns are `[*some subset of
      # equalities.keys in the index's declared order, range_column]`, or
      # nil if none exists - same "nil means scan" contract as every other
      # lookup_by_index* method. Unlike #lookup_by_index_range (single
      # column only), this walks a composite index's *last* column as the
      # range dimension while every other column is pinned to an exact
      # value - the same thing a real database does with a composite
      # B-tree index `(scope, position)` answering `WHERE scope = ? AND
      # position < ?` by seeking straight into the `scope` partition
      # instead of scanning the whole table (or, without this method, every
      # row in every OTHER scope too - see #lookup_by_index_range's
      # single-column limitation).
      #
      # `equalities` is allowed to carry MORE columns than the index's own
      # prefix needs (e.g. a paranoid model's `deleted_at: nil` riding
      # alongside `featured: true` when only `featured` is actually
      # indexed) - only the index's own declared prefix columns are read
      # out of it to build the lookup key, exactly like #lookup_by_index's
      # "index columns must be a subset of equalities.keys" contract (not
      # the other way around). Any equality condition the index prefix
      # doesn't cover is still safe to drop here: Relation#rows re-checks
      # the full condition against every candidate row afterward. When
      # several composite indexes could answer the same call, the one
      # covering the most columns wins, same tie-break as #lookup_by_index.
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

      # Returns matching row dups for an IN-list lookup (`where(column:
      # [v1, v2, ...])`), the same "nil means scan" contract as
      # #lookup_by_index/#lookup_by_index_range. This is what every
      # eager-loading batch query goes through
      # (Relation#preload_belongs_to's `where(id: owner_ids)`,
      # #preload_has_one/#preload_has_many/#preload_has_many_through's
      # `where(foreign_key: owner_ids)`) - without it, `includes(...)` on
      # any association was always a full table scan even though it only
      # ever needed a handful of specific ids, no matter how many other
      # secondary indexes existed elsewhere.
      #
      # `id` is always treated as indexed, with zero add_index calls
      # needed: #rows is already a Hash keyed by id, so this is just direct
      # O(1)-per-value hash lookups, same as #find. Any other column needs
      # a real single-column index (composite indexes can't answer an
      # IN-list on just one of their columns - which specific OTHER column
      # value would pair with each id in the list is ambiguous).
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

      # `id` is always "indexed" for free since `table_definition(table)[:rows]`
      # is already a Hash keyed by id - shared by #lookup_by_index's single-id
      # equality fast-path and #lookup_by_index_in's id IN-list fast-path, which
      # differed only in that one wrapped a single id and the other a list.
      def rows_by_id(table, ids)
        within_transaction(read_only: true) do
          rows = table_definition(table)[:rows]
          ids.map { |id| rows[id.to_i]&.dup }.compact
        end
      end

      # Finds [lo, hi) into `sorted` (ascending, unique values) covering
      # every value allowed by `operators`. A tighter bound on the same side
      # (both :gte and :gt given, say) - the caller (ConditionNode) never
      # produces that from a single #where, but even if it did, only one
      # side is honored here; the final Relation#rows `#select` against the
      # real condition still filters out anything that slipped through.
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

      # Builds the map/range metadata for an index from the table's current
      # rows - the same computation #add_index needs for a brand-new index
      # and #rebuild_indexes_covering needs to bring an existing index back
      # in sync after a backfill changed every row's value for one of its
      # columns.
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

        # Range queries (gt/gte/lt/lte, see #lookup_by_index_range) only
        # make sense for a single-column index - a composite key has no
        # single total order Predicates agrees with. range_capable stays
        # false if the column's values can't all be compared with each
        # other (e.g. mixed types slipped in), same defensive posture as
        # everywhere else in this store: an index that can't help safely
        # just means callers fall back to a full scan, never a wrong one.
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

        # The composite counterpart of range_capable above: a multi-column
        # index can still answer a range query on its LAST column as long
        # as every value observed for that last column, within a given
        # prefix (every column before it), can be totally ordered -
        # sorted_by_prefix holds one ascending, de-duplicated array of
        # last-column values per prefix key, exactly what
        # #lookup_by_index_equality_range binary-searches into. A
        # single-column index has no prefix to partition by, so this is
        # only ever attempted for columns.size > 1 (a single-column index
        # already gets the simpler range_capable path above).
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

      # Recomputes every index that covers `column` from scratch. Called
      # after #add_column backfills a value onto every existing row for a
      # column an index already existed on - see the comment on #add_column
      # for why a stale map here is a silent-wrong-results bug, not just a
      # missed optimization.
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

      # Keeps sorted_values ascending and unique as rows come and go, so
      # #lookup_by_index_range never has to re-sort. A comparison failure
      # (mixed, mutually-incomparable types landing in the same column)
      # disables range_capable rather than raising - the index still works
      # for #lookup_by_index equality, it just stops being usable for range
      # queries, the same safe-degrade posture as #add_index above.
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

      # Same incremental bookkeeping as #insert_sorted_value/
      # #remove_sorted_value, but scoped to one prefix key's own sorted
      # array (there is one such array per distinct prefix, not one for the
      # whole index) - #lookup_by_index_equality_range only ever binary-
      # searches the single array for the prefix it was asked about, so
      # every OTHER prefix's array must stay untouched by a row that
      # doesn't belong to it.
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
        Instrumentation.instrument('sql.prism', { operation: operation, table: table.to_s }.merge(extra)) do
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
