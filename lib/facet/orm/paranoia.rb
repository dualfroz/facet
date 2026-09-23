module Facet
  module Orm
    module Paranoia
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_paranoid(column: 'deleted_at')
          @paranoid_column = column.to_s
        end

        def paranoid_column
          @paranoid_column || (superclass.respond_to?(:paranoid_column) ? superclass.paranoid_column : nil)
        end

        def paranoid?
          !!paranoid_column
        end

        def paranoid_scope(relation)
          paranoid? ? relation.where(paranoid_column => nil) : relation
        end

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

      def soft_deleting?
        paranoid? && !@destroy_force
      end

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

      def really_destroy!
        destroy(force: true)
      end

      private

      def paranoid_delete?
        self.class.paranoid?
      end

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
