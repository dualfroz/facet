module Prism
  module Orm
    # ActiveRecord::Locking::Optimistic-lite. Raised when a save/destroy was
    # attempted against a lock_version the underlying row no longer has -
    # someone else already saved (or destroyed) the same record in between
    # this instance being loaded and this instance being saved.
    class StaleObjectError < StandardError
      attr_reader :record, :attempted_action

      def initialize(record, attempted_action)
        @record = record
        @attempted_action = attempted_action
        super("Attempted to #{attempted_action} a stale #{record.class} " \
              "(id=#{record.id.inspect}, lock_version=#{record.lock_version.inspect}); " \
              'it was already modified or destroyed by another process')
      end
    end

    # Optimistic locking: a `lock_version` integer column (auto-detected the
    # same way Model#touch_timestamps auto-detects created_at/updated_at -
    # present in the schema means enabled, no opt-in flag needed) turns a
    # blind last-write-wins update/destroy into one that raises instead of
    # silently clobbering a change made by another process in between this
    # record being loaded and being saved. The version check-and-increment
    # happens inside the same PStore transaction as the row write
    # (Store#update/#delete's lock_column/lock_version kwargs), so two
    # processes racing on the same row can never both succeed against the
    # same lock_version - the loser gets Store::StaleRowError, which Model
    # re-raises as the richer, record-carrying StaleObjectError above.
    module Locking
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def locking_column(name = nil)
          @locking_column = name.to_s if name
          @locking_column || 'lock_version'
        end

        def locking_enabled?
          columns.include?(locking_column)
        end
      end

      def lock_version
        self[self.class.locking_column]
      end
    end
  end
end
