module Prism
  module Orm
    # acts_as_paranoid-lite (Rails' `paranoia` gem, minus the gem): destroy
    # stamps a timestamp column instead of removing the row, and the default
    # query scope (Model.all) hides stamped rows so the rest of the app -
    # including dependent: :destroy cascades, which are just plain calls to
    # #destroy on each child - keeps working unmodified whether or not the
    # model opted in.
    #
    # Included in every Model like Locking/Enum/SecurePassword, inert until
    # a model calls `acts_as_paranoid`. Model#destroy itself (not this
    # module) branches on `paranoid_delete?` - see the Dirty module's
    # comment for why behavior like this lives behind an explicit call site
    # in Model rather than an override: Model defines #destroy directly in
    # its own class body, which always wins method lookup over a module
    # `destroy` defined here.
    module Paranoia
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_paranoid(column: 'deleted_at')
          @paranoid_column = column.to_s
        end

        # Same superclass-plus-own fallback as Callbacks#callbacks_for -
        # a subclass of a paranoid model is paranoid too unless it opts out
        # by declaring its own table without the column.
        def paranoid_column
          @paranoid_column || (superclass.respond_to?(:paranoid_column) ? superclass.paranoid_column : nil)
        end

        def paranoid?
          !!paranoid_column
        end

        # Called from Model.all/.count - narrows a relation to exclude
        # stamped rows. A no-op (returns the relation unchanged) for a
        # model that never called acts_as_paranoid.
        def paranoid_scope(relation)
          paranoid? ? relation.where(paranoid_column => nil) : relation
        end

        # Ignores the paranoid scope only - any other default_scope the
        # model declared still applies, matching Rails paranoia's
        # `with_deleted` (it is not `unscoped`, which drops every scope).
        def with_deleted
          @default_scope_block ? Relation.new(self).instance_exec(&@default_scope_block) : Relation.new(self)
        end

        def only_deleted
          with_deleted.not(paranoid_column => nil)
        end
      end

      def paranoid?
        self.class.paranoid?
      end

      def deleted?
        paranoid? && !self[self.class.paranoid_column].nil?
      end

      # True from inside a before_destroy hook (or after #destroy returns)
      # when this #destroy call is going to stamp the row rather than
      # remove it - false for a plain model, and false for a paranoid one
      # being destroyed with force: true (really_destroy!). Lets a hook
      # skip work that only makes sense for a permanent delete, such as
      # removing a file from disk a #restore should still be able to bring
      # back.
      def soft_deleting?
        paranoid? && !@destroy_force
      end

      # Un-stamps and saves. A plain attribute write + save, same as Rails
      # paranoia's #restore - it goes through the normal update path (so
      # before/after_save and before/after_update still fire), it just
      # never replays the before/after_destroy chain in reverse. Wrapped in
      # its own before_restore/after_restore pair (Callbacks#KINDS) rather
      # than reusing before/after_save, so a hook can tell "this update IS
      # a restore" apart from an ordinary attribute change - counter_cache
      # (Associable#define_counter_cache) uses exactly that to re-increment
      # a parent's count, since the plain after_create/after_destroy hooks
      # it already had never fire for a restore.
      #
      # `recursive: true` (Rails paranoia's own recursive restore) also
      # brings back this record's own dependent: :destroy children that are
      # themselves paranoid - see Associable#cascade_restore_dependent_
      # associations. Same caveat as the gem it mirrors: it restores EVERY
      # soft-deleted child regardless of whether trashing this record is
      # what deleted it, so a child deleted independently before its parent
      # was ever trashed comes back too.
      def restore(recursive: false)
        return self unless deleted?
        return self unless run_callbacks(:before_restore)
        self[self.class.paranoid_column] = nil
        @destroyed = false
        save
        cascade_restore_dependent_associations if recursive
        run_callbacks(:after_restore)
        self
      end

      # Bypasses the soft-delete branch entirely: removes the row for real,
      # through the exact same before/after_destroy + locking + dependent-
      # cascade path #destroy always uses.
      def really_destroy!
        destroy(force: true)
      end

      private

      def paranoid_delete?
        self.class.paranoid?
      end

      # Writes only the dirty attributes (the paranoid column stamp, plus
      # any other attribute this instance genuinely had pending), never the
      # full @attributes hash - see Model#dirty_attributes. This record's
      # own cascade_dependent_associations (Model#destroy runs it right
      # before this) may have just bumped one of THIS row's own columns out
      # of band (e.g. a counter_cache owned by this record, such as a
      # Comment's likes_count when its own Like gets destroyed as part of
      # the same cascade) via Store#increment_counter, which mutates the
      # stored row directly and never touches this instance's in-memory
      # @attributes. A full-hash `store.update(table, id, @attributes)`
      # would silently clobber that fresh mutation back to this instance's
      # stale cached value the moment the soft-delete stamp was written -
      # a real bug caught by examples/blog (Post -> Comment -> Like, all
      # three paranoid, Like counter_cache'd onto both Post and Comment).
      def soft_delete_row
        self[self.class.paranoid_column] = Time.now.utc
        stamp = dirty_attributes
        if self.class.locking_enabled?
          begin
            row = self.class.store.update(self.class.table_name, id, stamp,
                                           [self.class.locking_column, lock_version.to_i])
          rescue Store::StaleRowError
            raise StaleObjectError.new(self, :destroy)
          end
          @attributes[self.class.locking_column] = row[self.class.locking_column]
        else
          self.class.store.update(self.class.table_name, id, stamp)
        end
        changes_applied
      end
    end
  end
end
