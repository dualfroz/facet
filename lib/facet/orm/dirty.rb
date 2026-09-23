module Facet
  module Orm
    module Dirty
      def changed_attributes
        (@changed_attributes ||= {}).each_with_object({}) { |(k, v), h| h[k] = humanize_dirty_value(k, v) }
      end

      def changed?
        !(@changed_attributes ||= {}).empty?
      end

      def changed
        (@changed_attributes ||= {}).keys
      end

      def changes
        (@changed_attributes ||= {}).each_with_object({}) do |(key, old_value), result|
          result[key] = [humanize_dirty_value(key, old_value), humanize_dirty_value(key, @attributes[key])]
        end
      end

      def attribute_changed?(name)
        (@changed_attributes ||= {}).key?(name.to_s)
      end

      def attribute_was(name)
        name = name.to_s
        raw = attribute_changed?(name) ? @changed_attributes[name] : @attributes[name]
        humanize_dirty_value(name, raw)
      end

      def attribute_change(name)
        name = name.to_s
        return nil unless attribute_changed?(name)
        [humanize_dirty_value(name, @changed_attributes[name]), humanize_dirty_value(name, @attributes[name])]
      end

      def restore_attributes(names = nil)
        names = names ? names.map(&:to_s) : changed
        names.each do |name|
          next unless (@changed_attributes ||= {}).key?(name)
          @attributes[name] = @changed_attributes.delete(name)
        end
        self
      end

      def saved_changes
        (@saved_changes ||= {}).each_with_object({}) { |(k, v), h| h[k] = v.dup }
      end

      def saved_change_to_attribute?(name)
        (@saved_changes ||= {}).key?(name.to_s)
      end

      def saved_change_to_attribute(name)
        (@saved_changes ||= {})[name.to_s]
      end

      private

      def humanize_dirty_value(name, raw_value)
        return raw_value unless self.class.encrypted_attributes.key?(name.to_s)
        Encryption.decrypt_with_rotation(self.class.encryption_key_for(name),
                                          self.class.encryption_previous_keys_for(name),
                                          raw_value)
      end

      def track_attribute_change(key, old_value, new_value)
        return if old_value == new_value
        pending = (@changed_attributes ||= {})
        if pending.key?(key)
          pending.delete(key) if pending[key] == new_value
        else
          pending[key] = old_value
        end
      end

      def changes_applied
        @saved_changes = changes
        @changed_attributes = {}
      end

      def clear_changes_information
        @changed_attributes = {}
        @saved_changes = {}
      end
    end
  end
end
