module Facet
  module Jobs
    class Job
      class << self
        attr_reader :queue_name_value, :max_attempts_value, :backoff_value

        def queue_as(name)
          @queue_name_value = name.to_s
        end

        def retry_on(max_attempts: 5, backoff: :exponential, base_delay: 1)
          @max_attempts_value = max_attempts
          @backoff_value = { strategy: backoff, base_delay: base_delay }
        end

        def perform_later(*args, queue: nil, run_at: nil)
          default_queue.enqueue(
            job_class: name,
            args: args,
            queue_name: (queue || queue_name_value || 'default').to_s,
            max_attempts: max_attempts_value || 5,
            backoff: backoff_value || { strategy: :exponential, base_delay: 1 },
            run_at: run_at
          )
        end

        def perform_now(*args)
          new.perform(*args)
        end

        def default_queue
          Jobs.default_queue
        end
      end

      def perform(*args)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
