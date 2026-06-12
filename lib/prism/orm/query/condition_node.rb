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

