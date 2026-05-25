module Prism
  module Orm
    class RecordInvalid < StandardError; end
    class RecordNotFound < StandardError; end

    class Model
      include Validatable
      include Associable

      class << self
        def store
          @store || Orm.store
        end

        def store=(instance)
          @store = instance
        end

        def table_name(name = nil)
          @table_name = name.to_s if name
          @table_name || Inflector.tableize(self.name)
        end

        def columns
          @columns ||= store.columns(table_name)
        end

        def reset_schema!
          @columns = nil
          @schema_loaded = false
        end

        def load_schema!
          return if @schema_loaded
          columns.each do |column|
            next if method_defined?(column) && method_defined?("#{column}=")
            define_method(column) { self[column] }
            define_method("#{column}=") { |value| self[column] = value }
          end
          @schema_loaded = true
        end

        def instantiate(row)
          load_schema!
          allocate.tap { |record| record.send(:load_row, row) }
        end

        def create(attributes = {})
          new(attributes).tap(&:save)
        end

        def create!(attributes = {})
          record = new(attributes)
          record.save!
          record
        end

        def find(id)
          row = store.find(table_name, id)
          raise RecordNotFound, "no #{name} with id #{id}" unless row
          instantiate(row)
        end

        def all
          Relation.new(self)
        end

        def where(conditions)
          all.where(conditions)
        end

        def order(column, direction = :asc)
          all.order(column, direction)
        end

        def limit(count)
          all.limit(count)
        end

        def find_by(conditions)
          all.find_by(conditions)
        end

        def first
          all.first
        end

        def last
          all.last
        end

        def count
          store.count(table_name)
        end
      end

      def initialize(attributes = {})
        self.class.load_schema!
        @attributes = {}
        @new_record = true
        @destroyed = false
        assign(attributes)
      end

      def [](key)
        @attributes[key.to_s]
      end

      def []=(key, value)
        @attributes[key.to_s] = value
      end

      def id
        self['id']
      end

      def new_record?
        @new_record
      end

      def persisted?
        !@new_record && !@destroyed
      end

      def destroyed?
        @destroyed
      end

      def assign(attributes)
        attributes.each { |key, value| self[key] = value }
        self
      end

      def save
        return false unless valid?
        touch_timestamps
        if new_record?
          @attributes['id'] = self.class.store.insert(self.class.table_name, @attributes)
          @new_record = false
        else
          self.class.store.update(self.class.table_name, id, @attributes)
        end
        true
      end

      def save!
        raise RecordInvalid, errors.full_messages.join(', ') unless save
        true
      end

      def update(attributes)
        assign(attributes)
        save
      end

      def update!(attributes)
        assign(attributes)
        save!
      end

      def destroy
        self.class.store.delete(self.class.table_name, id) if persisted?
        @destroyed = true
        self
      end

      def reload
        row = self.class.store.find(self.class.table_name, id)
        raise RecordNotFound, "no #{self.class.name} with id #{id}" unless row
        load_row(row)
        self
      end

      def to_h
        @attributes.dup
      end

      def ==(other)
        other.is_a?(self.class) && !id.nil? && id == other.id
      end
      alias_method :eql?, :==

      def hash
        [self.class, id].hash
      end

      private

      def load_row(row)
        @attributes = row.dup
        @new_record = false
        @destroyed = false
        self
      end

      def touch_timestamps
        now = Time.now.utc
        columns = self.class.columns
        @attributes['created_at'] ||= now if columns.include?('created_at') && new_record?
        @attributes['updated_at'] = now if columns.include?('updated_at')
      end
    end
  end
end
