module Prism
  module Orm
    class RecordInvalid < StandardError; end
    class RecordNotFound < StandardError; end

    class Model
      include Validatable
      include Callbacks
      include Attributes
      include Dirty
      include Locking
      include Pessimistic
      include Paranoia
      include ListPosition
      include Serialization
      include Associable
      include NestedAttributes
      include SecurePassword
      include SecureToken
      include TokenFor
      include Encryption
      include Transactional
      include Enum

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
          raise RecordNotFound, "no #{name} with id #{id}" if paranoid? && !row[paranoid_column].nil?
          instantiate(row)
        end

        def all
          base = @default_scope_block ? Relation.new(self).instance_exec(&@default_scope_block) : Relation.new(self)
          paranoid_scope(base)
        end

        def unscoped
          Relation.new(self)
        end

        def default_scope(&block)
          @default_scope_block = block
        end

        def scopes
          @scopes ||= {}
        end

        def scope(name, body)
          scopes[name.to_sym] = body
          define_singleton_method(name) { |*args| all.instance_exec(*args, &body) }
        end

        def where(conditions)
          all.where(conditions)
        end

        def not(conditions)
          all.not(conditions)
        end

        def none
          all.none
        end

        def order(column, direction = :asc)
          all.order(column, direction)
        end

        def limit(count)
          all.limit(count)
        end

        def distinct
          all.distinct
        end

        def find_by(conditions)
          all.find_by(conditions)
        end

        def find_by!(conditions)
          all.find_by!(conditions)
        end

        def first
          all.first
        end

        def first!
          all.first!
        end

        def last
          all.last
        end

        def last!
          all.last!
        end

        def sum(column)
          all.sum(column)
        end

        def average(column)
          all.average(column)
        end

        def minimum(column)
          all.minimum(column)
        end

        def maximum(column)
          all.maximum(column)
        end

        def group(column)
          all.group(column)
        end

        def find_each(batch_size: 1000, &block)
          all.find_each(batch_size: batch_size, &block)
        end

        def find_in_batches(batch_size: 1000, &block)
          all.find_in_batches(batch_size: batch_size, &block)
        end

        def pick(*attributes)
          all.pick(*attributes)
        end

        def ids
          all.ids
        end

        def page(number)
          all.page(number)
        end

        def per(size)
          all.per(size)
        end

        def count
          (@default_scope_block || paranoid?) ? all.count : store.count(table_name)
        end

        # Raw counter bump used by belongs_to counter_cache - see
        # Store#increment_counter for why this bypasses Model#save.
        def increment_counter(counter_name, id, by = 1)
          store.increment_counter(table_name, id, counter_name, by)
        end

        def decrement_counter(counter_name, id, by = 1)
          increment_counter(counter_name, id, -by)
        end
      end

      def initialize(attributes = {})
        self.class.load_schema!
        @attributes = {}
        @new_record = true
        @destroyed = false
        apply_attribute_defaults
        assign(attributes)
      end

      def [](key)
        @attributes[key.to_s]
      end

      def []=(key, value)
        key = key.to_s
        track_attribute_change(key, @attributes[key], value)
        @attributes[key] = value
      end

      def id
        self['id']
      end

      # Rails' `to_param` hook: the value a model contributes to a URL when
      # a route segment is built from it. The router never calls this
      # itself (every url_for/path caller passes an explicit params hash,
      # see lib/prism/renderable.rb#url_for) - it exists so a model can
      # define ONE place to override (e.g. a slug) and callers opt in by
      # writing `post.to_param` instead of `post.id`.
      def to_param
        id&.to_s
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

      # Mass-assignment goes through a writer method when one is defined
      # (plain columns, associations, and virtual attributes like
      # SecurePassword's `password=`) so `Model.new(password: 'x')` runs
      # the same logic as calling `record.password = 'x'` by hand, instead
      # of poking the raw column hash and skipping it.
      def assign(attributes)
        attributes.each do |key, value|
          setter = "#{key}="
          respond_to?(setter) ? send(setter, value) : (self[key] = value)
        end
        self
      end

      # The whole before_save..after_save sequence runs inside one
      # `transaction` so after_commit only fires once persistence is truly
      # settled, and any exception raised by a callback rolls the write
      # back (StaleObjectError included) instead of leaving it half-done.
      # A `return false` from an aborted before_save/before_create still
      # unwinds through that transaction as an uncommitted attempt, which
      # is why after_rollback can fire even when nothing was ever written -
      # there was never anything to roll back on disk, but the write this
      # record attempted did not go through, matching what the hook name
      # promises.
      def save
        return false unless valid?
        touch_timestamps
        creating = new_record?
        self.class.transaction do
          enlist_in_transaction(creating ? :create : :update)
          return false unless run_callbacks(:before_save)
          return false unless run_callbacks(creating ? :before_create : :before_update)
          if creating
            initialize_lock_version
            @attributes['id'] = self.class.store.insert(self.class.table_name, @attributes)
            @new_record = false
          elsif self.class.locking_enabled?
            begin
              row = self.class.store.update(self.class.table_name, id, dirty_attributes,
                                             [self.class.locking_column, lock_version.to_i])
            rescue Store::StaleRowError
              raise StaleObjectError.new(self, :update)
            end
            @attributes[self.class.locking_column] = row[self.class.locking_column]
          else
            self.class.store.update(self.class.table_name, id, dirty_attributes)
          end
          changes_applied
          run_callbacks(creating ? :after_create : :after_update)
          run_callbacks(:after_save)
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

      # Cascaded dependent destroys run inside the same transaction as the
      # parent's own delete, so a failure partway through the cascade (or
      # in after_destroy) rolls back every row it already removed - not
      # just the parent - instead of leaving orphaned deletes behind.
      # `force: true` (from Paranoia#really_destroy!) always removes the row
      # for real even on a paranoid model, running the full callback/cascade/
      # locking sequence again even if the record was already soft-deleted -
      # matches Rails paranoia's really_destroy!, which re-runs the destroy
      # callbacks rather than assuming a soft-deleted record is untouchable.
      def destroy(force: false)
        return self if destroyed? && !force
        # Set before before_destroy runs (not after the paranoid-delete
        # branch below decides) so a before_destroy hook can tell #soft_deleting?
        # apart from a real delete - e.g. a hook that removes an uploaded
        # file from disk should only do that on a hard delete, not one a
        # paranoid model will still let #restore bring back.
        @destroy_force = force
        if !new_record?
          self.class.transaction do
            enlist_in_transaction(:destroy)
            return self unless run_callbacks(:before_destroy)
            cascade_dependent_associations
            if paranoid_delete? && !force
              soft_delete_row
            elsif self.class.locking_enabled?
              begin
                self.class.store.delete(self.class.table_name, id, [self.class.locking_column, lock_version.to_i])
              rescue Store::StaleRowError
                raise StaleObjectError.new(self, :destroy)
              end
            else
              self.class.store.delete(self.class.table_name, id)
            end
            @destroyed = true
            run_callbacks(:after_destroy)
          end
        else
          @destroyed = true
        end
        self
      end

      # ActiveRecord::Persistence#touch-lite: bumps updated_at (plus any
      # named extra attributes, e.g. `post.touch(:published_at)`) straight
      # on the stored row and skips validations and the save callback chain
      # entirely - only after_touch runs. This is what belongs_to ...,
      # touch: true rides on (see Associable#define_touch): touching a
      # comment's post whenever the comment is saved or destroyed changes
      # the post's #cache_key, which is exactly what busts a `cache post do
      # ... end` fragment that embeds the comment list.
      def touch(*names)
        raise RecordNotFound, "cannot touch a new record" if new_record?
        raise RecordNotFound, "cannot touch a destroyed record" if destroyed?
        now = Time.now.utc
        attributes = {}
        attributes['updated_at'] = now if self.class.columns.include?('updated_at')
        names.each { |name| attributes[name.to_s] = now }
        return self if attributes.empty?
        if self.class.locking_enabled?
          begin
            row = self.class.store.update(self.class.table_name, id, attributes,
                                           [self.class.locking_column, lock_version.to_i])
          rescue Store::StaleRowError
            raise StaleObjectError.new(self, :touch)
          end
          attributes[self.class.locking_column] = row[self.class.locking_column]
        else
          self.class.store.update(self.class.table_name, id, attributes)
        end
        attributes.each { |key, value| @attributes[key] = value }
        run_callbacks(:after_touch)
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

      # Fragment-cache key: changes whenever the record is touched, so a
      # `cache post do ... end` view fragment (Prism::CacheHelpers) keyed on
      # this automatically busts on update without anyone deleting the old
      # entry by hand.
      def cache_key
        base = "#{self.class.table_name}/#{id}"
        timestamp = self['updated_at'] || self['created_at']
        timestamp ? "#{base}-#{timestamp.to_i}" : base
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
        clear_changes_information
        self
      end

      def touch_timestamps
        now = Time.now.utc
        columns = self.class.columns
        self['created_at'] = now if columns.include?('created_at') && new_record? && self['created_at'].nil?
        self['updated_at'] = now if columns.include?('updated_at')
      end

      def initialize_lock_version
        return unless self.class.locking_enabled?
        @attributes[self.class.locking_column] = 0 if self[self.class.locking_column].nil?
      end

      # Only the columns this instance actually changed since it was
      # loaded/created, never the full @attributes hash - an UPDATE that
      # sends every column (including ones this instance never touched)
      # would overwrite any value another code path mutated directly on
      # the stored row in the meantime, such as a counter_cache bump
      # (Store#increment_counter) from a cascade_dependent_associations
      # step that runs on this very record earlier in the same #destroy,
      # or simply this instance's attributes being stale relative to a
      # concurrent write. Matches real UPDATE semantics (only SET the
      # columns that changed) instead of a full-row REPLACE.
      def dirty_attributes
        @attributes.slice(*changed)
      end
    end
  end
end
