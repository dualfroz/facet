module Prism
  module Orm
    module Query
      # A condition tree evaluated against a raw stored row (a String-keyed
      # Hash), letting Relation compose and/or/not without flattening
      # everything into a single Hash the way plain #where conditions do.
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

        # Column => scalar-value equalities that are guaranteed to hold for
        # every row this condition matches - the safe over-approximation
        # Relation#rows uses to pick a covering index instead of scanning
        # the whole table (see Store#lookup_by_index). Defaults to none;
        # only HashNode (a plain equality) and AndNode (the intersection of
        # both sides) can contribute any - Or/Not can't guarantee a shared
        # value across branches, so they contribute nothing, which just
        # means the caller falls back to a full scan, never a wrong result.
        def indexable_equalities
          {}
        end

        # Column => { gt:/gte:/lt:/lte: value } bounds that are guaranteed
        # to hold for every row this condition matches - the same safe
        # over-approximation idea as #indexable_equalities, but for a
        # contiguous range instead of a single value, letting Relation#rows
        # use Store#lookup_by_index_range (a binary search over a sorted
        # index) instead of a full scan. Defaults to none.
        def indexable_ranges
          {}
        end

        # Column => Array-of-values that are guaranteed to cover every row
        # this condition matches - the safe over-approximation Relation#rows
        # uses to pick Store#lookup_by_index_in (a direct id-hash lookup, or
        # an equality-index probe per value) instead of scanning the whole
        # table for an IN-list condition. Defaults to none.
        def indexable_in_lists
          {}
        end

        # Column => { equalities: {...}, bounds: {...} } for every column
        # that carries BOTH a range bound AND at least one OTHER column
        # pinned to an exact value in this same condition tree - the pair a
        # composite (scope, range-column) index answers via
        # Store#lookup_by_index_equality_range, the composite counterpart
        # of #indexable_ranges. Built once here from #indexable_equalities/
        # #indexable_ranges rather than overridden per subclass: both of
        # those already correctly aggregate across arbitrarily nested
        # AndNodes (that is their entire job), so this needs no HashNode-
        # or AndNode-specific logic of its own - a column can never appear
        # in both hashes at once (HashNode's #indexable_equalities
        # explicitly rejects Hash/Array/Range/Regexp values, exactly the
        # shapes #indexable_ranges requires), so `reject` below never
        # empties out the range column's own equality by accident.
        def indexable_equality_ranges
          equalities = indexable_equalities
          return {} if equalities.empty?

          indexable_ranges.each_with_object({}) do |(column, bounds), acc|
            prefix = equalities.reject { |c, _| c == column }
            acc[column] = { equalities: prefix, bounds: bounds } unless prefix.empty?
          end
        end

        # Array of matching row dups if this node can be answered entirely
        # from secondary indexes, or nil if the caller must fall back to a
        # full table scan - the same "nil means scan" contract as
        # Store#lookup_by_index. The default implementation covers HashNode
        # and AndNode: both only ever produce indexable_equalities/ranges/
        # in_lists/equality_ranges hashes, and this tries them against
        # `store` in that order (most selective first): an exact composite
        # match, then an IN-list, then an equality-prefix-plus-range
        # composite, then a plain single-column range. OrNode overrides
        # this (see below) since a Hash of column=>value can't represent
        # "candidates from either branch" - Not/MatchAll/MatchNone never
        # override it, so they fall through to nil via their empty
        # indexable_* hashes, exactly as before this method existed.
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
        # `model:` lets a Symbol/String enum label (`where(status: :draft)`,
        # `where(status: [:draft, :published])`, `where(status: { not_in:
        # [:archived] })`) be translated to the raw stored value the same
        # way Enum#enum_cast already does for a plain assignment - without
        # it, `Post.where(status: :draft)` would silently compare the raw
        # Integer column against the Symbol and never match. A raw value
        # passed directly (`where(status: 0)`) still round-trips unchanged.
        def initialize(conditions, model: nil)
          @conditions = conditions.transform_keys(&:to_s)
          @conditions = cast_enum_values(@conditions, model) if model
          @conditions = cast_encrypted_values(@conditions, model) if model
        end

        def matches?(row)
          @conditions.all? { |key, expected| Predicates.evaluate(row[key], expected) }
        end

        # Only conditions compared with a bare scalar (or nil) are safe to
        # feed into an index lookup - a Hash/Array/Range/Regexp expected
        # value means an operator, IN-list, range, or pattern match, none of
        # which narrow down to one exact stored value.
        def indexable_equalities
          @conditions.reject { |_key, expected| expected.is_a?(Hash) || expected.is_a?(Array) ||
                                                  expected.is_a?(Range) || expected.is_a?(Regexp) }
        end

        # A Hash expected-value is only a pure range when every operator key
        # is one of gt/gte/lt/lte - a mix with :in, :like, :ne, :is_null etc.
        # can't be represented as a single contiguous bound, so that column
        # is skipped here (safe: the caller just falls back to scanning).
        RANGE_OPERATORS = %i[gt gte lt lte].freeze

        def indexable_ranges
          @conditions.each_with_object({}) do |(column, expected), acc|
            bounds = range_bounds_for(expected)
            acc[column] = bounds if bounds
          end
        end

        # An Array expected-value is exactly an IN-list - the one Array
        # shape #indexable_equalities above has to reject (it can't collapse
        # to one scalar key), but it is precisely what
        # Store#lookup_by_index_in wants.
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

        # Same idea as cast_enum_values, but for `encrypts ..., deterministic:
        # true` columns (see Orm::Encryption) - `where(ssn: plaintext)` is
        # translated to the matching ciphertext before it ever reaches
        # Predicates.evaluate, which only ever sees raw stored values.
        def cast_encrypted_values(conditions, model)
          return conditions unless model.respond_to?(:encrypted_attributes)
          encrypted = model.encrypted_attributes
          return conditions if encrypted.empty?

          conditions.each_with_object({}) do |(column, value), acc|
            acc[column] = encrypted.key?(column) ? cast_encrypted_value(model, column, value) : value
          end
        end

        # model.encrypt_for_query returns a bare ciphertext normally, but an
        # Array of candidate ciphertexts (current key plus every previous
        # key still configured for rotation) once there is more than one
        # key that might have produced what is sitting on disk - flat_map +
        # Array(...) collapses both shapes into one flat IN-list without an
        # explicit branch on which one came back.
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

        # Merges per-column bounds from both sides rather than overwriting -
        # `where(age: { gte: 18 }).where(age: { lte: 65 })` must keep both
        # the lower and the upper bound, not just whichever side merge picks
        # last. When both sides constrain the same operator on the same
        # column (redundant/contradictory input), which value wins doesn't
        # matter for correctness: either is still a safe over-approximation
        # of the true intersection, and the final #matches? re-checks both.
        def indexable_ranges
          left = @left.indexable_ranges
          right = @right.indexable_ranges
          (left.keys | right.keys).each_with_object({}) do |column, acc|
            acc[column] = (left[column] || {}).merge(right[column] || {})
          end
        end

        # Unlike #indexable_ranges above, both sides having the SAME column
        # here is safely narrowed with a real intersection (not just "pick
        # one and let #matches? sort it out" as ranges do) - `where(id:
        # [1,2,3]).where(id: [2,3,4])` needs a row's id to be in both lists,
        # so `& ` is both a correct AND tighter candidate set than either
        # side alone, cheap for the small id/foreign-key lists these come
        # from in practice (eager-loading batches, not user-supplied IN
        # clauses of unbounded size).
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

        # An Or is only index-answerable when BOTH branches are - covering
        # just one side and then still scanning the rest of the table for
        # the other buys nothing over scanning for the whole condition, so
        # this deliberately returns nil (scan) rather than "index one side,
        # scan for the other" false economy. When both sides do hit an
        # index (e.g. `Comment.approved.or(where(user_id: id))` once both
        # `status` and `user_id` carry an index), the union of both id sets
        # is exactly the Or's result set - matches? still re-checks every
        # candidate afterward in Relation#rows, so a row present in both
        # branches being deduplicated here is just an optimization, not a
        # correctness requirement.
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
