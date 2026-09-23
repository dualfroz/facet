require 'set'

module Facet
  module Orm
    class NPlusOneViolation < StandardError; end

    module NPlusOneDetector
      class << self
        def enable!(threshold: 2, io: $stderr, raise_on_violation: false)
          @threshold = threshold
          @io = io
          @raise_on_violation = raise_on_violation
          @enabled = true
        end

        def disable!
          @enabled = false
        end

        def enabled?
          !!@enabled
        end

        def threshold
          @threshold || 2
        end

        def raise_on_violation?
          !!@raise_on_violation
        end

        def io
          @io || $stderr
        end

        def record_lazy_load(owner, association_name)
          return unless enabled?
          tracker[[owner.class.name, association_name]] << owner_key(owner)
        end

        def reset!
          Thread.current[:facet_n_plus_one_tracker] = nil
        end

        def report!(context = {})
          return unless enabled?
          violations.each do |(class_name, association_name), count|
            emit(class_name, association_name, count, context)
          end
          reset!
        end

        private

        def owner_key(owner)
          owner.respond_to?(:id) && owner.id ? owner.id : owner.object_id
        end

        def emit(class_name, association_name, count, context)
          message = "N+1 query detected: #{class_name}##{association_name} lazily loaded for " \
                    "#{count} separate #{class_name} records#{context_suffix(context)} - " \
                    "add .includes(:#{association_name}) to the query that loaded them"
          io.puts(message)
          raise NPlusOneViolation, message if raise_on_violation?
        end

        def context_suffix(context)
          context.empty? ? '' : " (#{context.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')})"
        end

        def violations
          tracker.each_with_object({}) do |(key, owner_keys), acc|
            acc[key] = owner_keys.size if owner_keys.size >= threshold
          end
        end

        def tracker
          Thread.current[:facet_n_plus_one_tracker] ||= Hash.new { |h, k| h[k] = Set.new }
        end
      end
    end
  end
end
