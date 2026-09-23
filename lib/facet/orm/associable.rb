module Facet
  module Orm
    module Associable
      DEPENDENT_OPTIONS = [nil, :destroy, :nullify].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

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
