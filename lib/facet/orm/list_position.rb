module Facet
  module Orm
    module ListPosition
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_list(column: :position, scope: nil)
          @list_position_column = column.to_s
          @list_position_scope_column = scope && scope.to_s
          before_create :facet_list_position_append_on_create
          before_update :facet_list_position_switch_scope_on_update
          after_destroy :facet_list_position_close_gap
          after_restore :facet_list_position_reappend_on_restore
        end

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

      def shift_siblings_at_or_after(position, by:)
        column = self.class.list_position_column
        list_scope_relation.where(column => { gte: position }).each do |sibling|
          self.class.store.increment_counter(self.class.table_name, sibling.id, column, by) unless persisted? && sibling.id == id
        end
      end

      def facet_list_position_append_on_create
        column = self.class.list_position_column
        if list_position
          shift_siblings_at_or_after(list_position, by: 1)
        else
          self[column] = (list_scope_relation.maximum(column) || 0) + 1
        end
      end

      def facet_list_position_switch_scope_on_update
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
        new_bottom = self.class.all.where(scope_column => self[scope_column]).maximum(column)
        self[column] = (new_bottom || 0) + 1
      end

      def facet_list_position_close_gap
        pos = list_position
        return unless pos
        column = self.class.list_position_column
        list_scope_relation.where(column => { gt: pos }).each do |sibling|
          self.class.store.increment_counter(self.class.table_name, sibling.id, column, -1)
        end
      end

      def facet_list_position_reappend_on_restore
        column = self.class.list_position_column
        new_position = (list_scope_relation.maximum(column) || 0) + 1
        self.class.store.increment_counter(self.class.table_name, id, column, new_position - list_position.to_i)
        @attributes[column] = new_position
      end
    end
  end
end
