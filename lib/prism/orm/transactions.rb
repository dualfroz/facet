module Prism
  module Orm
    # Raised inside a `transaction` block to roll back every write made so
    # far without the error propagating to the caller - mirrors
    # ActiveRecord::Rollback exactly (`transaction { ...; raise Rollback }`
    # returns nil from the block, no exception visible outside it). Any
    # OTHER exception rolls back the same way but keeps propagating past
    # the transaction boundary, same as Rails.
    class Rollback < StandardError; end

    # Tracks, per Store, which records took part in the currently-open
    # (possibly nested) transaction, so after_commit/after_rollback fire
    # exactly once, only when the OUTERMOST transaction actually finishes.
    # A plain nested `transaction` block is not a real commit point - it
    # mirrors Store#within_transaction, which already flattens nested calls
    # into the single enclosing PStore transaction, so a raise from deep
    # inside a chain of nested `Model.transaction` blocks still rolls back
    # every write made by any of them, not just the innermost one.
    #
    # `transaction(requires_new: true)`, in contrast, is a real SAVEPOINT:
    # its participants live in their own frame on `@frames`, separate from
    # whatever frame is beneath them, so a raise inside only rolls back and
    # fires after_rollback for that frame - the parent frame(s) are
    # untouched and keep waiting for the real outermost commit/rollback.
    class TransactionRegistry
      def initialize
        @depth = 0
        @frames = []
      end

      def nested?
        @depth.positive?
      end

      def within
        @depth += 1
        @frames.push([]) if @depth == 1
        outermost = @depth == 1
        committed = false
        begin
          result = yield
          committed = true
          result
        rescue Rollback
          nil
        ensure
          @depth -= 1
          finish(committed) if outermost
        end
      end

      # Runs block in a fresh participant frame with a table snapshot taken
      # first. On success the frame is merged into its parent, still
      # waiting for that parent's own commit/rollback. On failure the store
      # is restored to the snapshot and after_rollback fires immediately for
      # just this frame - Rollback is swallowed (mirrors `within`), any
      # other exception still propagates so an enclosing transaction can
      # also decide to abort.
      def within_savepoint(store)
        @depth += 1
        @frames.push([])
        snapshot = store.snapshot_tables
        begin
          result = yield
          frame = @frames.pop
          @frames.last.concat(frame)
          result
        rescue Rollback
          rollback_frame(store, snapshot)
          nil
        rescue StandardError
          rollback_frame(store, snapshot)
          raise
        ensure
          @depth -= 1
        end
      end

      # No-op outside any open transaction, so a bare `record.save` with no
      # surrounding `Model.transaction` block never queues a participant
      # for a commit/rollback that will never come from here (the write's
      # OWN implicit transaction, opened by Model#save itself, is what
      # fires its callbacks in that case).
      def enlist(record, operation)
        @frames.last << [record, operation] if @depth.positive?
      end

      private

      def rollback_frame(store, snapshot)
        store.restore_tables(snapshot)
        @frames.pop.each { |record, operation| record.send(:fire_transaction_callback, :after_rollback, operation) }
      end

      def finish(committed)
        batch = @frames.pop
        kind = committed ? :after_commit : :after_rollback
        batch.each { |record, operation| record.send(:fire_transaction_callback, kind, operation) }
      end
    end

    # Mixed into Model: gives every model class/instance a `transaction`
    # that groups writes (its own and any other model sharing the same
    # underlying Store) into one atomic unit, plus after_commit/
    # after_rollback hooks that only fire once that unit is truly settled.
    module Transactional
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def transaction(requires_new: false, &block)
          store.transaction_with_callbacks(requires_new: requires_new, &block)
        end
      end

      def transaction(requires_new: false, &block)
        self.class.transaction(requires_new: requires_new, &block)
      end

      private

      def enlist_in_transaction(operation)
        self.class.store.transaction_registry.enlist(self, operation)
      end

      def fire_transaction_callback(kind, operation)
        run_callbacks(kind, operation)
      end
    end
  end
end
