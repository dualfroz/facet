module Facet
  module Jobs
    class Worker
      def initialize(queue, queue_name: nil, error_handler: nil)
        @queue = queue
        @queue_name = queue_name
        @error_handler = error_handler
      end

      def work_off
        processed = 0
        while (job = @queue.claim_next!(queue_name: @queue_name))
          process(job)
          processed += 1
        end
        processed
      end

      def process(job)
        Instrumentation.instrument('perform_job.facet', job_class: job[:job_class],
                                                          job_id: job[:id],
                                                          queue_name: @queue_name) do |payload|
          job_class = resolve_job_class(job[:job_class])
          job_class.new.perform(*job[:args])
          @queue.mark_completed(job[:id])
          payload[:status] = 'completed'
        end
        true
      rescue StandardError => e
        @error_handler&.call(e, job)
        @queue.mark_failed(job[:id], e)
        false
      end

      private

      def resolve_job_class(name)
        Object.const_get(name)
      end
    end
  end
end
