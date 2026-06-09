module Prism
  module Orm
    # ActiveModel::Dirty-lite: tracks unsaved attribute changes on a Model
    # instance. Like Callbacks/Validatable, this is included as a plain
    # module and invoked from explicit call sites in Model (Model#[]=,
    # #load_row, #save) rather than overriding those methods itself -
    # Model defines them directly in its own class body, which always
    # wins method lookup over an included module, so overriding them here
    # would silently do nothing.
    module Dirty
      # Attribute name => value it held before the current unsaved change.
      # Frozen-ish read view; callers get a copy, not the internal hash.
      def changed_attributes
        (@changed_attributes ||= {}).each_with_object({}) { |(k, v), h| h[k] = humanize_dirty_value(k, v) }
      end

      def changed?
        !(@changed_attributes ||= {}).empty?
      end

      def changed
        (@changed_attributes ||= {}).keys
      end

      # { "title" => [old_value, current_value], ... }
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

      # Reverts unsaved changes (all, or just the given attribute names)
      # back to the value they held after the last load/save.
      def restore_attributes(names = nil)
        names = names ? names.map(&:to_s) : changed
        names.each do |name|
          next unless (@changed_attributes ||= {}).key?(name)
          @attributes[name] = @changed_attributes.delete(name)
        end
        self
      end

      # Snapshot of what #changes held right after the most recent #save,
      # matching Rails' saved_changes/previous_changes. Empty before the
      # first save and while there are only unsaved (not-yet-persisted)
      # changes - use #changes for those.
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

      # An `encrypts`-backed attribute stores ciphertext in @attributes -
      # track_attribute_change/#[]= only ever see the raw column value, so
      # without this every dirty-tracking read (changes/attribute_was/...)
      # would leak ciphertext bytes instead of the plaintext the model's
      # own reader returns. Encryption is always included on Model (see
      # Model's include list), so encrypted_attributes is always defined,
      # just empty for a class with no `encrypts` at all - the common case
      # skips straight past this and returns the raw value unchanged.
      def humanize_dirty_value(name, raw_value)
        return raw_value unless self.class.encrypted_attributes.key?(name.to_s)
        Encryption.decrypt_with_rotation(self.class.encryption_key_for(name),
                                          self.class.encryption_previous_keys_for(name),
                                          raw_value)
      end

      # Called from Model#[]= on every write. A value written back to what
      # it was before the current chain of unsaved changes started is not
      # dirty anymore (matches ActiveModel: set then un-set == no change).
      def track_attribute_change(key, old_value, new_value)
        return if old_value == new_value
        pending = (@changed_attributes ||= {})
        if pending.key?(key)
          pending.delete(key) if pending[key] == new_value
        else
          pending[key] = old_value
        end
      end

      # Called right after a successful insert/update: today's unsaved
      # changes become saved_changes, and the record is clean again.
      def changes_applied
        @saved_changes = changes
        @changed_attributes = {}
      end

      # Called from Model#load_row (fresh load or #reload): no changes,
      # nothing saved yet in this instance's lifetime.
      def clear_changes_information
        @changed_attributes = {}
        @saved_changes = {}
      end
    end
  end
end
