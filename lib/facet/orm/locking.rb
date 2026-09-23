module Facet
  module Orm
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
