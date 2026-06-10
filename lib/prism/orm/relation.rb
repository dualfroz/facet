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

      def preload(records)
        return if @includes_value.empty? || records.empty?
        @includes_value.each { |name| preload_association(name, records) }
      end

      def preload_association(name, records)
        meta = @model.associations[name]
        raise ArgumentError, "unknown association #{name.inspect} on #{@model}" unless meta

        case meta[:type]
        when :belongs_to then preload_belongs_to(name, meta, records)
        when :has_one then preload_has_one(name, meta, records)
        when :has_many then preload_has_many(name, meta, records)
        when :has_many_through then preload_has_many_through(name, meta, records)
        when :has_one_through then preload_has_one_through(name, meta, records)
        else
          raise ArgumentError, "includes does not support association type #{meta[:type].inspect} (#{name.inspect})"
        end
      end

      def preload_belongs_to(name, meta, records)
        return preload_belongs_to_polymorphic(name, meta, records) if meta[:polymorphic]

        target = Object.const_get(meta[:class_name])
        ids = records.map { |record| record[meta[:foreign_key]] }.compact.uniq
        by_id = target.where(id: ids).each_with_object({}) { |record, hash| hash[record.id] = record }
        records.each { |record| record.association_cache[name] = by_id[record[meta[:foreign_key]]] }
      end

      # Polymorphic belongs_to can point at rows in several different
      # tables, so a single `where(id: ids)` on one target class would be
      # wrong - group owners by their type column first and issue one
      # batched query per distinct target type (still far fewer queries
      # than one per owner for any realistic mix of types).
      def preload_belongs_to_polymorphic(name, meta, records)
        loaded = {}
        records.group_by { |record| record[meta[:type_key]] }.each do |type_name, group|
          next if type_name.nil?
          ids = group.map { |record| record[meta[:foreign_key]] }.compact.uniq
          Object.const_get(type_name).where(id: ids).each { |target| loaded[[type_name, target.id]] = target }
        end
        records.each do |record|
          record.association_cache[name] = loaded[[record[meta[:type_key]], record[meta[:foreign_key]]]]
        end
      end

      def preload_has_one(name, meta, records)
        target = Object.const_get(meta[:class_name])
        condition = { meta[:foreign_key] => records.map(&:id).compact.uniq }
        condition[meta[:type_key]] = @model.name if meta[:type_key]
        by_owner = target.where(condition).each_with_object({}) do |record, hash|
          hash[record[meta[:foreign_key]]] = record
        end
        records.each { |record| record.association_cache[name] = by_owner[record.id] }
      end

      def preload_has_many(name, meta, records)
        target = Object.const_get(meta[:class_name])
        condition = { meta[:foreign_key] => records.map(&:id).compact.uniq }
        condition[meta[:type_key]] = @model.name if meta[:type_key]
        grouped = target.where(condition).to_a.group_by { |record| record[meta[:foreign_key]] }
        records.each { |record| record.association_cache[name] = grouped[record.id] || [] }
      end

      # Batches the through-association's records for all owners in one
      # query, then batches the source association on top of *those*
      # records (recursing into another Relation's preloader), so an
      # `includes(:commenters)` costs two queries total regardless of how
      # many posts or comments are involved. The through step can itself be
      # has_many/has_one (owner.id looked up by foreign key on the through
      # table) or belongs_to (owner holds the foreign key, so several owners
      # can share one through record) - each shape needs its own batching.
      def preload_has_many_through(name, meta, records)
        through_meta = @model.associations[meta[:through]]
        unless through_meta
          raise ArgumentError, "unknown through association #{meta[:through].inspect} on #{@model}"
        end

        case through_meta[:type]
        when :has_many, :has_one
          preload_has_many_through_by_foreign_key(name, meta, through_meta, records)
        when :belongs_to
          preload_has_many_through_by_belongs_to(name, meta, through_meta, records)
        else
          raise ArgumentError, "includes does not support #{name.inspect} (through a #{through_meta[:type]} " \
                                "association); through must be has_many, has_one, or belongs_to"
        end
      end

      def preload_has_many_through_by_foreign_key(name, meta, through_meta, records)
        through_target = Object.const_get(through_meta[:class_name])
        owner_ids = records.map(&:id).compact.uniq
        through_records = through_target.where(through_meta[:foreign_key] => owner_ids).to_a
        through_by_owner = through_records.group_by { |record| record[through_meta[:foreign_key]] }

        through_target.all.send(:preload_association, meta[:source], through_records) unless through_records.empty?

        records.each do |record|
          owned = through_by_owner[record.id] || []
          record.association_cache[name] = Associable.collect_through(owned, meta[:source])
        end
      end

      # has_many :through where the through step is a belongs_to, e.g.
      # `Comment belongs_to :post` plus `Comment has_many :co_commenters,
      # through: :post, source: :commenters` (everyone else who commented on
      # the same post). Several owners can point at the same through record,
      # so it is batched by id rather than by foreign key, then the source
      # association is batched on top of the deduped through records - still
      # two queries total no matter how many owners share a through record.
      def preload_has_many_through_by_belongs_to(name, meta, through_meta, records)
        through_target = Object.const_get(through_meta[:class_name])
        through_ids = records.map { |record| record[through_meta[:foreign_key]] }.compact.uniq
        through_by_id = through_target.where(id: through_ids).each_with_object({}) do |record, hash|
          hash[record.id] = record
        end

        through_target.all.send(:preload_association, meta[:source], through_by_id.values) unless through_by_id.empty?

        records.each do |record|
          through_record = through_by_id[record[through_meta[:foreign_key]]]
          record.association_cache[name] = Associable.collect_through(through_record, meta[:source])
        end
      end

      # Single-record counterpart to preload_has_many_through: batches the
      # through-association for all owners (has_one or belongs_to, so at
      # most one record per owner), then batches the source association on
      # top of those through-records, so an `includes(:account_history)`
      # costs two queries total regardless of how many owners are involved.
      def preload_has_one_through(name, meta, records)
        through_meta = @model.associations[meta[:through]]
        unless through_meta
          raise ArgumentError, "unknown through association #{meta[:through].inspect} on #{@model}"
        end

        unless [:has_one, :belongs_to].include?(through_meta[:type])
          raise ArgumentError, "includes does not support #{name.inspect} (through a #{through_meta[:type]} " \
                                "association); through must be has_one or belongs_to"
        end

        case through_meta[:type]
        when :has_one then preload_has_one(meta[:through], through_meta, records)
        when :belongs_to then preload_belongs_to(meta[:through], through_meta, records)
        end

        through_records = records.filter_map { |record| record.association_cache[meta[:through]] }.uniq
        through_target = Object.const_get(through_meta[:class_name])
        through_target.all.send(:preload_association, meta[:source], through_records) unless through_records.empty?

        records.each do |record|
          through_record = record.association_cache[meta[:through]]
          record.association_cache[name] = through_record && through_record.association_cache[meta[:source]]
        end
      end

      def rows
        candidates = indexed_candidates || @model.store.all(@model.table_name)
        filtered = candidates.select { |row| @condition.matches?(row) }
        filtered = apply_order(filtered)
        filtered = filtered.uniq if @distinct_value
        filtered = filtered.drop(@offset_value) if @offset_value
        filtered = filtered.first(@limit_value) if @limit_value
        filtered
      end

      # nil means "no covering index, caller must scan the whole table";
      # an Array (possibly empty) means an index narrowed it down already.
      # The subsequent #select against the full @condition is still run
      # unconditionally so this is always correct even when the equalities
      # or range bounds extracted here are a strict subset of the real
      # condition (e.g. an extra clause on a non-indexed column in the same
      # #where). The actual equality-then-in_list-then-range-then-Or-union
      # logic lives on the condition tree itself (ConditionNode#indexed_
      # candidates) since OrNode needs to recurse into both branches, which
      # a flat Hash of column=>value can't express.
      def indexed_candidates
        @condition.indexed_candidates(@model.store, @model.table_name)
      end

      def apply_order(rows)
        return rows unless @order_by
        column, direction = @order_by
        sorted = rows.sort_by { |row| [row[column].nil? ? 0 : 1, row[column]] }
        direction == :desc ? sorted.reverse : sorted
      end
    end
  end
end
