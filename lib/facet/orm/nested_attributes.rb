module Facet
  module Orm
    module NestedAttributes
      class TooManyRecords < StandardError; end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def nested_attributes_options
          @nested_attributes_options ||= {}
        end

        def accepts_nested_attributes_for(name, allow_destroy: false, reject_if: nil, limit: nil)
          name = name.to_sym
          meta = associations[name]
          raise ArgumentError, "no association #{name.inspect} to accept nested attributes for" unless meta
          unless %i[has_many has_one].include?(meta[:type])
            raise ArgumentError,
                  "accepts_nested_attributes_for only supports has_many/has_one (#{name.inspect} is #{meta[:type].inspect})"
          end

          nested_attributes_options[name] = {
            allow_destroy: allow_destroy, reject_if: reject_if, limit: limit, collection: meta[:type] == :has_many
          }

          define_method("#{name}_attributes=") do |attributes|
            (@nested_attributes_pending ||= {})[name] = attributes
          end

          register_nested_attributes_callbacks(name)
        end

        private

        def nested_attributes_registered
          @nested_attributes_registered ||= []
        end

        def register_nested_attributes_callbacks(name)
          return if nested_attributes_registered.include?(name)
          nested_attributes_registered << name

          before_save { process_nested_attributes_before_save(name) }
          after_save { process_nested_attributes_after_save(name) }
        end
      end

      private

      def process_nested_attributes_before_save(name)
        pending = @nested_attributes_pending&.delete(name)
        return unless pending

        options = self.class.nested_attributes_options[name]
        meta = self.class.associations[name]
        built = build_nested_records(name, pending, options, meta)
        (@nested_attributes_built ||= {})[name] = built
        throw :abort if built.any? { |entry| entry[:invalid] }
      end

      def process_nested_attributes_after_save(name)
        built = @nested_attributes_built&.delete(name)
        return unless built

        meta = self.class.associations[name]
        built.each do |entry|
          record = entry[:record]
          if entry[:destroy]
            record.destroy if record.persisted?
          else
            record[meta[:foreign_key]] = id
            record[meta[:type_key]] = self.class.name if meta[:type_key]
            record.save
          end
        end
      end

      def build_nested_records(name, pending, options, meta)
        target_class = Object.const_get(meta[:class_name])
        entries = options[:collection] ? normalize_nested_collection(pending) : [pending]

        if options[:limit] && entries.size > options[:limit]
          raise NestedAttributes::TooManyRecords, "maximum #{options[:limit]} records are allowed for #{name}"
        end

        entries.each_with_object([]) do |raw_attrs, list|
          entry = build_one_nested_record(name, raw_attrs, options, meta, target_class)
          list << entry if entry
        end
      end

      def build_one_nested_record(name, raw_attrs, options, meta, target_class)
        attrs = stringify_nested_keys(raw_attrs)
        id_value = attrs.delete('id')
        destroy_flag = nested_truthy?(attrs.delete('_destroy'))

        if id_value.nil? || id_value == ''
          return nil if reject_nested_record?(options[:reject_if], attrs)
          record = target_class.new
        else
          record = find_existing_nested_record(target_class, meta, id_value)
          if record.nil?
            errors.add(name, "references an invalid or inaccessible #{Inflector.underscore(meta[:class_name])}")
            return { record: nil, destroy: false, invalid: true }
          end
        end

        return { record: record, destroy: true, invalid: false } if destroy_flag && options[:allow_destroy]

        record.assign(attrs)
        if record.valid?
          { record: record, destroy: false, invalid: false }
        else
          record.errors.full_messages.each { |message| errors.add(name, message) }
          { record: record, destroy: false, invalid: true }
        end
      end

      def find_existing_nested_record(target_class, meta, id_value)
        return nil if new_record?
        record = target_class.find(id_value)
        return nil unless record[meta[:foreign_key]] == id
        return nil if meta[:type_key] && record[meta[:type_key]] != self.class.name
        record
      rescue RecordNotFound
        nil
      end

      def normalize_nested_collection(pending)
        case pending
        when Hash then pending.values
        when Array then pending
        else raise ArgumentError, "expected a Hash or Array of attribute hashes, got #{pending.class}"
        end
      end

      def stringify_nested_keys(attrs)
        attrs.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def nested_truthy?(value)
        [true, 'true', '1', 1].include?(value)
      end

      def reject_nested_record?(reject_if, attrs)
        case reject_if
        when nil then false
        when :all_blank
          attrs.values.all? { |value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
        when Symbol then send(reject_if, attrs)
        when Proc then reject_if.call(attrs)
        else false
        end
      end
    end
  end
end
