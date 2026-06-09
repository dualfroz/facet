module Prism
  module Orm
    # ActiveRecord-style lifecycle hooks: before/after_validation, _save,
    # _create, _update, _destroy. A hook is either a method name (Symbol) or
    # a block, run via `send`/`instance_exec` in registration order.
    #
    # `throw :abort` from a `before_*` hook halts the chain and makes the
    # caller (valid?/save/destroy) bail out, matching Rails 5+ semantics -
    # returning `false` from a hook does NOT halt anything, only the throw does.
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
        # `on:` restricts an after_commit/after_rollback hook to one
        # operation (:create/:update/:destroy), same idea as Rails'
        # `after_commit on: :create` - ignored (always matches) for every
        # other kind, since those already run inside a single known phase.
        KINDS.each do |kind|
          define_method(kind) do |method_name = nil, on: nil, &block|
            own_callbacks[kind] << { hook: (method_name || block), on: on }
          end
        end

        def own_callbacks
          @own_callbacks ||= Hash.new { |hash, key| hash[key] = [] }
        end

        # Superclass hooks run before the subclass's own, same fallback
        # pattern as Controller#before_actions - a plain `@ivar ||= []` per
        # class would silently drop everything a base model class declared.
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
