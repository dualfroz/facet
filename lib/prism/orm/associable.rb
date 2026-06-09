module Prism
  module Orm
    module Associable
      DEPENDENT_OPTIONS = [nil, :destroy, :nullify].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      # Normalizes a has_many/has_one/belongs_to result into a flat, deduped
      # (by id) array of records, walking each `through` record's `source`
      # association. Shared by the lazy reader in ClassMethods and by
      # Relation's eager-load preloader.
      def self.collect_through(through_records, source_name)
        seen = {}
        as_array(through_records).each_with_object([]) do |through_record, list|
          as_array(through_record.send(source_name)).each do |target|
            next if target.nil? || seen[target.id]
            seen[target.id] = true
            list << target
          end
        end
      end

      def self.as_array(value)
        case value
        when nil then []
        when Enumerable then value.to_a
        else [value]
        end
      end

      # Resolves the counter_cache column name against `klass.name` lazily,
      # at hook-execution time rather than when `belongs_to` is declared -
      # an anonymous `Class.new(Model) { belongs_to ..., counter_cache: true }`
      # (the pattern this test suite uses throughout, constant-set only
      # after the class body runs) would otherwise capture `klass.name ==
      # nil` forever, silently producing a bogus "_count" column.
      def self.counter_cache_column(klass, counter_cache)
        counter_cache == true ? "#{Inflector.tableize(klass.name)}_count" : counter_cache.to_s
      end

      module ClassMethods
        def associations
          @associations ||= {}
        end

        def belongs_to(name, class_name: nil, foreign_key: nil, polymorphic: false, counter_cache: false, touch: false)
          if polymorphic
            return define_belongs_to_polymorphic(name, foreign_key: foreign_key, counter_cache: counter_cache,
                                                        touch: touch)
          end

          target = class_name || Inflector.camelize(name.to_s)
          key = (foreign_key || "#{name}_id").to_s
          associations[name.to_sym] = { type: :belongs_to, class_name: target, foreign_key: key }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            value = self[key]
            cache[name] = value.nil? ? nil : Object.const_get(target).find(value)
          end

          define_method("#{name}=") do |record|
            self[key] = record&.id
            association_cache[name] = record
          end

          define_counter_cache(target, key, counter_cache) if counter_cache
          define_touch(target, key, touch) if touch
        end

        def has_one(name, class_name: nil, foreign_key: nil, dependent: nil, through: nil, source: nil, as: nil)
          return define_has_one_through(name, through: through, source: source, dependent: dependent) if through
          return define_has_one_polymorphic(name, class_name: class_name, as: as, dependent: dependent) if as

          validate_dependent!(dependent)
          target = class_name || Inflector.camelize(name.to_s)
          key = (foreign_key || "#{Inflector.underscore(self.name)}_id").to_s
          associations[name.to_sym] = { type: :has_one, class_name: target, foreign_key: key, dependent: dependent }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            cache[name] = Object.const_get(target).find_by(key => id)
          end

          define_method("#{name}=") do |record|
            if record
              record[key] = id
              record.save
            end
            association_cache[name] = record
          end
        end

        def has_many(name, class_name: nil, foreign_key: nil, dependent: nil, through: nil, source: nil, as: nil)
          return define_has_many_through(name, through: through, source: source, dependent: dependent) if through
          return define_has_many_polymorphic(name, class_name: class_name, as: as, dependent: dependent) if as

          validate_dependent!(dependent)
          target = class_name || Inflector.classify(name.to_s)
          key = (foreign_key || "#{Inflector.underscore(self.name)}_id").to_s
          associations[name.to_sym] = { type: :has_many, class_name: target, foreign_key: key, dependent: dependent }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            Object.const_get(target).where(key => id)
          end
        end

        def has_and_belongs_to_many(name, class_name: nil, join_table: nil, foreign_key: nil,
                                    association_foreign_key: nil)
          target = class_name || Inflector.classify(name.to_s)
          jt = (join_table || habtm_join_table_name(self.name, target)).to_s
          left_key = (foreign_key || "#{Inflector.underscore(self.name)}_id").to_s
          right_key = (association_foreign_key || "#{Inflector.underscore(target)}_id").to_s
          associations[name.to_sym] = {
            type: :habtm, class_name: target, join_table: jt, left_key: left_key, right_key: right_key
          }

          define_method(name) do
            HabtmCollection.new(self, target: Object.const_get(target), join_table: jt,
                                      left_key: left_key, right_key: right_key)
          end

          define_method("#{name}=") do |records|
            send(name).replace(records)
          end
        end

        def dependent_associations
          associations.select { |_, meta| meta[:dependent] }
        end

        private

        # has_many :through - derives its collection by walking an existing
        # association (`through`) and reading another association (`source`)
        # off each of those records, e.g. `has_many :commenters, through:
        # :comments, source: :commenter`. Unlike plain has_many this holds no
        # foreign key of its own, so `dependent` is not supported.
        def define_has_many_through(name, through:, source:, dependent: nil)
          raise ArgumentError, 'has_many :through requires a through: association' unless through
          if dependent
            raise ArgumentError, "dependent is not supported with has_many :through (#{name.inspect})"
          end
          source_name = (source || Inflector.singularize(name.to_s)).to_sym
          associations[name.to_sym] = { type: :has_many_through, through: through.to_sym, source: source_name }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            cache[name] = Associable.collect_through(send(through), source_name)
          end
        end

        # has_one :through - single-record counterpart to has_many :through:
        # walks an existing has_one/belongs_to association (`through`) and
        # reads another single-record association (`source`) off it, e.g.
        # `has_one :account_history, through: :account`. Holds no foreign key
        # of its own, so `dependent` is not supported.
        def define_has_one_through(name, through:, source:, dependent: nil)
          raise ArgumentError, 'has_one :through requires a through: association' unless through
          if dependent
            raise ArgumentError, "dependent is not supported with has_one :through (#{name.inspect})"
          end
          source_name = (source || name).to_sym
          associations[name.to_sym] = { type: :has_one_through, through: through.to_sym, source: source_name }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            through_record = send(through)
            cache[name] = through_record && through_record.send(source_name)
          end
        end

        # belongs_to :commentable, polymorphic: true - the owner holds both
        # the foreign key (commentable_id) and a type column (commentable_type,
        # the target's class name as a string), so the same foreign key can
        # point at rows in different tables depending on the record.
        #
        # counter_cache:/touch: both work here too, exactly as on a plain
        # belongs_to, except which owner CLASS to reach for is read off
        # type_key per record/per saved-change instead of being the single
        # fixed class_name a plain belongs_to always has - see the type_key:
        # branches in define_counter_cache/define_touch below.
        def define_belongs_to_polymorphic(name, foreign_key:, counter_cache: false, touch: false)
          key = (foreign_key || "#{name}_id").to_s
          type_key = "#{name}_type"
          associations[name.to_sym] = { type: :belongs_to, polymorphic: true, foreign_key: key, type_key: type_key }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            target_id = self[key]
            target_type = self[type_key]
            cache[name] = (target_id.nil? || target_type.nil?) ? nil : Object.const_get(target_type).find(target_id)
          end

          define_method("#{name}=") do |record|
            self[key] = record&.id
            self[type_key] = record&.class&.name
            association_cache[name] = record
          end

          define_counter_cache(nil, key, counter_cache, type_key: type_key) if counter_cache
          define_touch(nil, key, touch, type_key: type_key) if touch
        end

        # has_many :comments, as: :commentable - the inverse side of a
        # polymorphic belongs_to: scopes the child table by both the foreign
        # key and the type column so rows belonging to a different owner
        # class with the same id never leak in.
        def define_has_many_polymorphic(name, class_name:, as:, dependent: nil)
          validate_dependent!(dependent)
          target = class_name || Inflector.classify(name.to_s)
          key = "#{as}_id"
          type_key = "#{as}_type"
          associations[name.to_sym] = {
            type: :has_many, class_name: target, foreign_key: key, type_key: type_key, dependent: dependent
          }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            Object.const_get(target).where(key => id, type_key => self.class.name)
          end
        end

        # has_one :preview_image, as: :imageable - single-record counterpart
        # to define_has_many_polymorphic.
        def define_has_one_polymorphic(name, class_name:, as:, dependent: nil)
          validate_dependent!(dependent)
          target = class_name || Inflector.camelize(name.to_s)
          key = "#{as}_id"
          type_key = "#{as}_type"
          associations[name.to_sym] = {
            type: :has_one, class_name: target, foreign_key: key, type_key: type_key, dependent: dependent
          }

          define_method(name) do
            cache = association_cache
            return cache[name] if cache.key?(name)
            NPlusOneDetector.record_lazy_load(self, name)
            cache[name] = Object.const_get(target).find_by(key => id, type_key => self.class.name)
          end

          define_method("#{name}=") do |record|
            if record
              record[key] = id
              record[type_key] = self.class.name
              record.save
            end
            association_cache[name] = record
          end
        end

        # belongs_to ..., counter_cache: true - keeps a denormalized count of
        # this class's own rows on the parent row pointed at by the foreign
        # key, so `post.comments.count` becomes a plain column read
        # (`post.comments_count`) instead of a query, mirroring Rails'
        # `belongs_to :post, counter_cache: true` on the child (Comment)
        # side. `counter_cache: true` defaults the column to this class's
        # own table name pluralized-as-a-suffix (Comment -> comments_count);
        # `counter_cache: :custom_column` names it explicitly. The three
        # hooks run inside the same transaction as the triggering
        # create/update/destroy (Store#increment_counter is reentrant), so a
        # rolled-back child write rolls the counter bump back with it.
        #
        # type_key: is set by define_belongs_to_polymorphic - a polymorphic
        # owner's class varies per row (read off that column), unlike a
        # plain belongs_to's single fixed target_class_name, so id and type
        # are tracked as a PAIR everywhere below instead of an id alone.
        # Either half of that pair can in principle change independently of
        # the other on update, so old/new are resolved separately for each.
        def define_counter_cache(target_class_name, foreign_key, counter_cache, type_key: nil)
          after_create do
            owner_id = self[foreign_key]
            owner_type = type_key ? self[type_key] : target_class_name
            next unless owner_id && owner_type
            column = Associable.counter_cache_column(self.class, counter_cache)
            Object.const_get(owner_type).increment_counter(column, owner_id)
          end

          after_destroy do
            owner_id = self[foreign_key]
            owner_type = type_key ? self[type_key] : target_class_name
            next unless owner_id && owner_type
            column = Associable.counter_cache_column(self.class, counter_cache)
            Object.const_get(owner_type).decrement_counter(column, owner_id)
          end

          # A restore (Paranoia#restore) never goes through after_create -
          # it un-stamps and updates an existing row - so without this a
          # counter_cache'd child coming back from the trash would leave
          # its parent's count permanently short by one.
          after_restore do
            owner_id = self[foreign_key]
            owner_type = type_key ? self[type_key] : target_class_name
            next unless owner_id && owner_type
            column = Associable.counter_cache_column(self.class, counter_cache)
            Object.const_get(owner_type).increment_counter(column, owner_id)
          end

          after_update do
            fk_changed = saved_change_to_attribute?(foreign_key)
            type_changed = type_key && saved_change_to_attribute?(type_key)
            next unless fk_changed || type_changed

            unchanged_id = [self[foreign_key], self[foreign_key]]
            old_id, new_id = fk_changed ? saved_change_to_attribute(foreign_key) : unchanged_id
            current_type = type_key ? self[type_key] : target_class_name
            unchanged_type = [current_type, current_type]
            old_type, new_type = type_changed ? saved_change_to_attribute(type_key) : unchanged_type

            column = Associable.counter_cache_column(self.class, counter_cache)
            Object.const_get(old_type).decrement_counter(column, old_id) if old_id && old_type
            Object.const_get(new_type).increment_counter(column, new_id) if new_id && new_type
          end
        end

        # belongs_to ..., touch: true - Model#touch's the owner (updated_at,
        # plus `touch: :column` for an explicit extra one) whenever this
        # child is saved or destroyed. Unlike counter_cache this fires on
        # EVERY save, not only when the foreign key itself changes - editing
        # a comment's body with no change to its post_id still needs to bust
        # the post's #cache_key. If the foreign key did change, the OLD
        # owner is touched too (mirrors Rails: both sides of a reassignment
        # see their cache invalidated), same before/after split as
        # counter_cache's after_update above. A parent that no longer
        # exists (already destroyed elsewhere) is left alone rather than
        # raising - the child's own save/destroy already succeeded and
        # should not fail retroactively over stale cache bookkeeping.
        #
        # after_destroy skips the touch entirely when
        # destroyed_by_association_foreign_key names this same foreign key
        # - i.e. when this child is being destroyed because ITS OWNER is
        # cascading `has_many ..., dependent: :destroy` into it (see
        # apply_dependent above). Without this guard, a paranoid,
        # optimistically-locked owner running that cascade would have each
        # cascaded child's after_destroy re-`find` the owner and bump its
        # lock_version - so by the time the owner's own soft/hard delete
        # finally writes using the lock_version it captured once at the top
        # of its #destroy, that captured value no longer matches what the
        # cascade already advanced it to, and the owner's own delete raises
        # StaleObjectError over a write it never asked for. An owner that's
        # disappearing in this same operation was never going to have
        # anyone observe the bumped-then-discarded timestamp anyway - only
        # the exception would have been visible. Mirrors Rails'
        # ActiveRecord::Associations `destroyed_by_association` guard on
        # its own touch callback, for exactly this reason.
        #
        # type_key: is set by define_belongs_to_polymorphic - which class to
        # Object.const_get and #find on varies per row (read off that
        # column) instead of being the single fixed target_class_name a
        # plain belongs_to always touches, so id and type travel together as
        # a pair everywhere below, same as in define_counter_cache above.
        def define_touch(target_class_name, foreign_key, touch, type_key: nil)
          extra_column = touch == true ? nil : touch.to_s
          perform_touch = lambda do |owner_type, owner_id|
            next unless owner_id && owner_type
            begin
              record = Object.const_get(owner_type).find(owner_id)
              extra_column ? record.touch(extra_column) : record.touch
            rescue RecordNotFound, StaleObjectError
              nil
            end
          end

          after_save do
            current_type = type_key ? self[type_key] : target_class_name
            perform_touch.call(current_type, self[foreign_key])

            fk_changed = saved_change_to_attribute?(foreign_key)
            type_changed = type_key && saved_change_to_attribute?(type_key)
            if fk_changed || type_changed
              old_id = fk_changed ? saved_change_to_attribute(foreign_key)[0] : self[foreign_key]
              old_type = type_changed ? saved_change_to_attribute(type_key)[0] : current_type
              perform_touch.call(old_type, old_id)
            end
          end

          after_destroy do
            unless destroyed_by_association_foreign_key == foreign_key
              owner_type = type_key ? self[type_key] : target_class_name
              perform_touch.call(owner_type, self[foreign_key])
            end
          end
        end

        def validate_dependent!(dependent)
          return if DEPENDENT_OPTIONS.include?(dependent)
          raise ArgumentError, "unsupported dependent: #{dependent.inspect} (use :destroy or :nullify)"
        end

        def habtm_join_table_name(a, b)
          [Inflector.tableize(a), Inflector.tableize(b)].sort.join('_')
        end
      end

      def association_cache
        @association_cache ||= {}
      end

      # Set on a child by apply_dependent right before it destroys that
      # child as part of its owner's own dependent: :destroy cascade,
      # naming the foreign key that made it a dependent. belongs_to ...,
      # touch: true's after_destroy hook (see define_touch) checks this to
      # skip touching an owner that is disappearing in this very same
      # operation - not just to dodge a redundant write, but because the
      # owner's own destroy already captured its lock_version before the
      # cascade started, and cascade-triggered touches bumping it further
      # would make that captured version stale by the time the owner's own
      # soft/hard delete finally writes (see the long comment on
      # define_touch). Mirrors Rails' own ActiveRecord::Associations
      # `destroyed_by_association` for exactly this reason.
      attr_accessor :destroyed_by_association_foreign_key

      private

      def cascade_dependent_associations
        self.class.dependent_associations.each do |name, meta|
          cascade_one_association(meta)
        end
      end

      def cascade_one_association(meta)
        target = Object.const_get(meta[:class_name])
        condition = { meta[:foreign_key] => id }
        condition[meta[:type_key]] = self.class.name if meta[:type_key]
        case meta[:type]
        when :has_many
          apply_dependent(target.where(condition).to_a, meta)
        when :has_one
          record = target.find_by(condition)
          apply_dependent(record ? [record] : [], meta)
        end
      end

      def apply_dependent(records, meta)
        case meta[:dependent]
        when :destroy
          records.each do |record|
            record.destroyed_by_association_foreign_key = meta[:foreign_key]
            record.destroy
          end
        when :nullify
          updates = { meta[:foreign_key] => nil }
          updates[meta[:type_key]] = nil if meta[:type_key]
          records.each { |record| record.update(updates) }
        end
      end

      # Mirror of cascade_dependent_associations for Paranoia#restore(recursive:
      # true): only :destroy associations can have anything to bring back
      # (:nullify never removed a row, it just detached one), and only a
      # paranoid target could possibly have a soft-deleted row sitting in
      # only_deleted - a plain model's dependent: :destroy children were
      # already removed for real when the parent was trashed, so there is
      # nothing left to restore. Recurses into each restored child with
      # recursive: true itself, so restoring a Post brings its Comments back
      # AND each Comment's own paranoid dependents (its Likes), if any.
      def cascade_restore_dependent_associations
        self.class.dependent_associations.each do |name, meta|
          next unless meta[:dependent] == :destroy
          restore_one_dependent_association(meta)
        end
      end

      def restore_one_dependent_association(meta)
        target = Object.const_get(meta[:class_name])
        return unless target.respond_to?(:paranoid?) && target.paranoid?
        condition = { meta[:foreign_key] => id }
        condition[meta[:type_key]] = self.class.name if meta[:type_key]
        case meta[:type]
        when :has_many
          target.only_deleted.where(condition).to_a.each { |record| record.restore(recursive: true) }
        when :has_one
          record = target.only_deleted.find_by(condition)
          record.restore(recursive: true) if record
        end
      end
    end
  end
end
