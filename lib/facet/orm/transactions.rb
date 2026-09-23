module Facet
  module Orm
    class Rollback < StandardError; end

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
