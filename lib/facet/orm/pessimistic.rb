module Facet
  module Orm
    module Pessimistic
      class UnpersistedRecordError < StandardError
        def initialize
          super('cannot lock a record that has not been saved yet')
        end
      end

      class DirtyRecordError < StandardError
        def initialize
          super('cannot lock a record with unsaved changes - save or ' \
                'discard them first, reload would silently drop them')
        end
      end

      def lock!
        raise UnpersistedRecordError if id.nil?
        raise DirtyRecordError if changed?
        transaction { reload }
        self
      end

      def with_lock
        transaction do
          lock!
          yield self
        end
      end
    end
  end
end
