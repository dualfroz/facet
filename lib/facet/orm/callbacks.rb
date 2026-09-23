module Facet
  module Orm
    module Callbacks
      KINDS = %i[
        before_validation after_validation
        before_save after_save
        before_create after_create
        before_update after_update
        before_destroy after_destroy
        before_restore after_restore
        after_commit after_rollback
        after_touch
      ].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        KINDS.each do |kind|
          define_method(kind) do |method_name = nil, on: nil, &block|
            own_callbacks[kind] << { hook: (method_name || block), on: on }
          end
        end

        def own_callbacks
          @own_callbacks ||= Hash.new { |hash, key| hash[key] = [] }
        end

        def callbacks_for(kind)
          inherited = superclass.respond_to?(:callbacks_for) ? superclass.callbacks_for(kind) : []
          inherited + own_callbacks[kind]
        end
      end

      private

      def run_callbacks(kind, operation = nil)
        catch(:abort) {
          self.class.callbacks_for(kind).each do |entry|
            next if entry[:on] && entry[:on] != operation
            hook = entry[:hook]
            hook.is_a?(Proc) ? instance_exec(&hook) : send(hook)
          end
          return true
        }
        false
      end
    end
  end
end
