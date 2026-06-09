module Prism
  module Orm
    # acts_as_list-lite (the `acts_as_list` gem, minus the gem): a model
    # opts in with `acts_as_list column: :position, scope: :some_column`
    # and gets a manually reorderable list - a fresh record is appended to
    # the bottom of its scope automatically, #move_higher/#move_lower swap
    # a record with its immediate neighbor, #move_to_top/#move_to_bottom/
    # #insert_at jump it anywhere else, and destroying (or paranoid-
    # soft-deleting, see Paranoia) a record closes the gap it leaves
    # behind so positions inside a scope stay a dense 1..N run - the
    # invariant every method here relies on to find "the item right above/
    # below me" without scanning the whole scope.
    #
    # Every write to the position column goes through Store#increment_counter
    # (the same raw, callback-free, non-locking bump belongs_to counter_cache
    # uses) rather than Model#save - reordering siblings is bookkeeping, not
    # a change any of THEIR validations/callbacks/after_commit hooks should
    # ever see, exactly like a counter_cache bump. It also means moving a
    # record around never touches ITS optimistic lock_version (if any) or
    # updated_at - matches Rails' acts_as_list, which uses update_all/
    # decrement_all for the same reason.
    module ListPosition
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # `scope:` is a single column name whose stored value groups
        # siblings that share one ordering (e.g. `scope: :category_id`) -
        # left nil, the whole table is one list. Unlike most flags in this
        # ORM, an explicit nil scope is a real, meaningful choice (global
        # list) that must be told apart from "acts_as_list was never
        # called on this class at all" - see list_position_scope_column's
        # `defined?` check below, the same reason Paranoia can't just use
        # `@ivar || superclass...` for its column.
        def acts_as_list(column: :position, scope: nil)
          @list_position_column = column.to_s
          @list_position_scope_column = scope && scope.to_s
          before_create :prism_list_position_append_on_create
          before_update :prism_list_position_switch_scope_on_update
          after_destroy :prism_list_position_close_gap
          after_restore :prism_list_position_reappend_on_restore
        end

        # Same superclass-plus-own fallback as Paranoia#paranoid_column -
        # a subclass of an acts_as_list model is one too unless it
        # declares its own table without the column.
        def list_position_column
          @list_position_column || (superclass.respond_to?(:list_position_column) ? superclass.list_position_column : nil)
        end

        def list_position_scope_column
          return @list_position_scope_column if defined?(@list_position_scope_column)
          superclass.respond_to?(:list_position_scope_column) ? superclass.list_position_scope_column : nil
        end

        def acts_as_list?
          !!list_position_column
        end
      end

      def list_position
        self[self.class.list_position_column]
      end

      # The rest of this record's list - narrowed to its scope value (if
      # any) - going through Model.all/.where so paranoid_scope already
      # hides soft-deleted siblings the same way it hides them everywhere
      # else, and default_scope (if the model declared one) still applies.
      def list_scope_relation
        relation = self.class.all
        scope_column = self.class.list_position_scope_column
        scope_column ? relation.where(scope_column => self[scope_column]) : relation
      end

      def higher_item
        pos = list_position
        return nil unless pos
        list_scope_relation.where(self.class.list_position_column => { lt: pos })
                            .order(self.class.list_position_column, :desc).first
      end

      def lower_item
        pos = list_position
        return nil unless pos
        list_scope_relation.where(self.class.list_position_column => { gt: pos })
                            .order(self.class.list_position_column, :asc).first
      end

      def first_in_list?
        persisted? && higher_item.nil?
      end

      def last_in_list?
        persisted? && lower_item.nil?
      end

      # Swaps this record's position with the sibling directly above/below
      # it - a no-op (returns self unchanged) when already first/last,
      # exactly like the gem: there is nothing higher/lower to swap with.
      #
      # Wrapped in with_lock (Pessimistic, every Model includes it) rather
      # than reading the neighbor first and opening a transaction only for
      # the write: higher_item/lower_item used to run in their OWN
      # read-only transaction, which releases Store's file lock the moment
      # it returns (Store#within_transaction), before swap_list_position_with
      # opened its own separate write transaction. Two processes calling
      # move_higher/move_lower on the same scope at nearly the same time
      # could both read the same neighbor in that gap and then both write a
      # swap against it, corrupting the dense 1..N position invariant every
      # method in this file relies on (duplicate or skipped positions) -
      # the exact same class of lost-update race Pessimistic closes for a
      # plain counter, just reachable here through two separate queries
      # instead of one. with_lock keeps a single transaction (and therefore
      # the file lock) open from the reload through the neighbor lookup and
      # the write, so a concurrent mover blocks until this one fully
      # commits instead of interleaving with it - see
      # test_orm_list_position.rb's forked-process tests.
      def move_higher
        with_lock do
          neighbor = higher_item
          swap_list_position_with(neighbor) if neighbor
        end
        self
      end

      def move_lower
        with_lock do
          neighbor = lower_item
          swap_list_position_with(neighbor) if neighbor
        end
        self
      end

      def move_to_top
        with_lock do
          target = list_scope_relation.minimum(self.class.list_position_column)
          insert_at(target) if target && target != list_position
        end
        self
      end

      def move_to_bottom
        with_lock do
          target = list_scope_relation.maximum(self.class.list_position_column)
          insert_at(target) if target && target != list_position
        end
        self
      end

      # General-purpose reposition for an already-persisted record: shifts
      # every sibling strictly between the old and new position by one
      # (toward the gap this move opens up) inside a single transaction,
      # then moves this record itself - the same three-step shift the gem
      # does with update_all, just expressed as one increment_counter call
      # per affected row since this Store has no bulk UPDATE.
      #
      # Also wrapped in with_lock - a caller reaching this directly (not
      # through move_to_top/move_to_bottom) hits the same TOCTOU window as
      # move_higher/move_lower did: old_position used to be read from
      # whatever self happened to hold in memory, which could already be
      # stale by the time the write transaction opened. Nesting inside an
      # already-open with_lock (as move_to_top/move_to_bottom now do) is
      # safe - Store#within_transaction/Pessimistic#lock! are both
      # reentrant on an already-open transaction, so this does not try to
      # take the file lock twice.
      def insert_at(new_position)
        raise RecordNotFound, "cannot reposition a #{self.class} that is not persisted" unless persisted?
        column = self.class.list_position_column
        with_lock do
          old_position = list_position
          next if old_position == new_position

          if old_position.nil?
            shift_siblings_at_or_after(new_position, by: 1)
          elsif new_position < old_position
            list_scope_relation.where(column => { gte: new_position, lt: old_position }).each do |sibling|
              self.class.store.increment_counter(self.class.table_name, sibling.id, column, 1) unless sibling.id == id
            end
          else
            list_scope_relation.where(column => { gt: old_position, lte: new_position }).each do |sibling|
              self.class.store.increment_counter(self.class.table_name, sibling.id, column, -1) unless sibling.id == id
            end
          end
          self.class.store.increment_counter(self.class.table_name, id, column, new_position - old_position.to_i)
        end
        @attributes[column] = new_position
        self
      end

      private

      def swap_list_position_with(other)
        column = self.class.list_position_column
        self_position = list_position
        other_position = other[column]
        self.class.transaction do
          self.class.store.increment_counter(self.class.table_name, other.id, column, self_position - other_position)
          self.class.store.increment_counter(self.class.table_name, id, column, other_position - self_position)
        end
        other.instance_variable_get(:@attributes)[column] = self_position
        @attributes[column] = other_position
      end

      # Shared by insert_at's "no prior position" branch and by the
      # before_create hook when a caller assigns a position explicitly
      # (e.g. Model.create!(position: 2, ...)) instead of relying on the
      # bottom-of-list default - existing rows at or past the target slide
      # down to make room for the record about to occupy it.
      def shift_siblings_at_or_after(position, by:)
        column = self.class.list_position_column
        list_scope_relation.where(column => { gte: position }).each do |sibling|
          self.class.store.increment_counter(self.class.table_name, sibling.id, column, by) unless persisted? && sibling.id == id
        end
      end

      def prism_list_position_append_on_create
        column = self.class.list_position_column
        if list_position
          shift_siblings_at_or_after(list_position, by: 1)
        else
          self[column] = (list_scope_relation.maximum(column) || 0) + 1
        end
      end

      # Fires only when the scope column itself is dirty (e.g. Post#featured
      # flipped by an edit form - see examples/blog) - an ordinary update
      # that never touches the scope column leaves list_position completely
      # alone. attribute_was(scope_column) reads the PRE-change value while
      # this hook still runs inside the same before_update Dirty sees it in
      # (see Dirty#attribute_was), which is why the "close the gap" query
      # below is built by hand against that old value instead of going
      # through list_scope_relation - that helper always reads self's
      # CURRENT (already-reassigned) scope value, which by now is the new
      # one this record is about to join, not the one it is leaving.
      def prism_list_position_switch_scope_on_update
        scope_column = self.class.list_position_scope_column
        return unless scope_column && attribute_changed?(scope_column)
        column = self.class.list_position_column
        old_scope_value = attribute_was(scope_column)
        old_position = self[column]
        if old_position
          self.class.all.where(scope_column => old_scope_value, column => { gt: old_position }).each do |sibling|
            self.class.store.increment_counter(self.class.table_name, sibling.id, column, -1)
          end
        end
        # The store row this record occupies still holds the OLD scope
        # value (this update has not been written yet), so a plain query
        # for the new scope's current bottom naturally excludes self
        # without needing to filter it out by id, same as
        # prism_list_position_reappend_on_restore relies on for the same
        # reason.
        new_bottom = self.class.all.where(scope_column => self[scope_column]).maximum(column)
        self[column] = (new_bottom || 0) + 1
      end

      # Runs for both a real delete and a paranoid soft-delete (Model#destroy
      # runs after_destroy either way - see Paranoia) since in both cases
      # the row stops showing up in list_scope_relation (paranoid_scope
      # hides it, or it is just gone), so either way the gap it leaves
      # needs closing the same way.
      def prism_list_position_close_gap
        pos = list_position
        return unless pos
        column = self.class.list_position_column
        list_scope_relation.where(column => { gt: pos }).each do |sibling|
          self.class.store.increment_counter(self.class.table_name, sibling.id, column, -1)
        end
      end

      # A restored record's OLD position (untouched by soft-delete/restore,
      # which only ever stamp/clear the paranoid column) may now collide
      # with whatever slid down into that slot while it was trashed (see
      # prism_list_position_close_gap above) - reappending it to the
      # bottom, exactly like a fresh create, is the same call Rails
      # paranoia + acts_as_list users hit this same way: a restored record
      # does not reclaim its old spot, it rejoins at the end.
      def prism_list_position_reappend_on_restore
        column = self.class.list_position_column
        new_position = (list_scope_relation.maximum(column) || 0) + 1
        self.class.store.increment_counter(self.class.table_name, id, column, new_position - list_position.to_i)
        @attributes[column] = new_position
      end
    end
  end
end
