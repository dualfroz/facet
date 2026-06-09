require 'set'

module Prism
  module Orm
    # Raised by NPlusOneDetector.report! when raise_on_violation? is set and
    # at least one association crossed the threshold - lets a test suite
    # turn a silent perf regression into a hard failure instead of a log
    # line nobody reads.
    class NPlusOneViolation < StandardError; end

    # Bullet-lite: flags the classic N+1 pattern - the SAME association
    # lazily loaded (association_cache miss, i.e. NOT pre-populated by
    # Relation's `includes` preloader) for more than `threshold` DISTINCT
    # owner records within a single request span. Opt-in and thread-local,
    # so it costs nothing unless explicitly enabled (development/test) and
    # stays correct under concurrent requests running on separate threads.
    #
    # Hooked from two places: Associable's lazy reader fallbacks call
    # #record_lazy_load right before running the query a cache miss would
    # otherwise trigger silently; Application#dispatch calls #reset! at the
    # start of each request's instrumented span and #report! right after it
    # finishes, matching Rails' request-scoped Bullet middleware without
    # needing an actual middleware layer (this framework's `process_action.
    # prism` instrumentation event is emitted only AFTER the whole action
    # already ran - see Instrumentation::Bus#instrument - so there is no
    # "before" hook to subscribe to; the reset/report pair is called
    # directly instead).
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

        # Called by Associable's lazy reader fallbacks. `owner` is the
        # record the association is being read off of (`self` in the
        # reader); distinct owners are what count towards the threshold, so
        # reading the same association twice on the SAME instance (a plain
        # cache-warm re-read once #record_lazy_load has already fired once
        # this request) does not inflate the count further.
        def record_lazy_load(owner, association_name)
          return unless enabled?
          tracker[[owner.class.name, association_name]] << owner_key(owner)
        end

        # Resets the thread-local tracker - called once per request, before
        # any association reader can possibly fire.
        def reset!
          Thread.current[:prism_n_plus_one_tracker] = nil
        end

        # Called once per request, after the whole action ran. Emits one
        # line per association whose lazy loads crossed `threshold`, then
        # clears the tracker so a violation is never reported twice.
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
          Thread.current[:prism_n_plus_one_tracker] ||= Hash.new { |h, k| h[k] = Set.new }
        end
      end
    end
  end
end
