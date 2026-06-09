require 'pstore'
require 'fileutils'

module Prism
  module Jobs
    # Persisted, PStore-backed job queue: enqueue/dequeue with per-job
    # scheduling (run_at), retry bookkeeping (attempts/backoff) and a
    # dead-letter table for jobs that exhausted their retries. Survives
    # process restarts since everything is written to disk on every change.
    class Queue
      DEFAULT_BACKOFF = { strategy: :exponential, base_delay: 1 }.freeze

      def initialize(path)
        @path = path
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless directory == '.' || Dir.exist?(directory)
        @pstore = PStore.new(path)
        @pstore.transaction do
          @pstore[:jobs] ||= {}
          @pstore[:dead_letter] ||= {}
          @pstore[:next_id] ||= 1
        end
      end

      def enqueue(job_class:, args: [], queue_name: 'default', max_attempts: 5, backoff: DEFAULT_BACKOFF, run_at: nil)
        @pstore.transaction do
          id = @pstore[:next_id]
          @pstore[:next_id] += 1
          @pstore[:jobs][id] = {
            id: id,
            job_class: job_class.to_s,
            args: args,
            queue_name: queue_name.to_s,
            status: 'pending',
            attempts: 0,
            max_attempts: max_attempts,
            backoff: backoff,
            run_at: run_at || Time.now,
            last_error: nil,
            enqueued_at: Time.now
          }
          id
        end
      end

      # Returns the earliest pending job whose run_at has arrived, or nil.
      # Does not mark it processing - callers should call #mark_processing
      # before performing it, so a crash mid-perform leaves a trace.
      def next_ready(queue_name: nil)
        @pstore.transaction(true) do
          candidates = @pstore[:jobs].values.select do |job|
            job[:status] == 'pending' && job[:run_at] <= Time.now &&
              (queue_name.nil? || job[:queue_name] == queue_name.to_s)
          end
          candidates.min_by { |job| job[:run_at] }&.dup
        end
      end

      def mark_processing(id)
        @pstore.transaction { @pstore[:jobs][id][:status] = 'processing' }
      end

      # Atomically finds the earliest ready job and flips it to 'processing'
      # in a single write transaction (PStore takes an exclusive flock for
      # the whole block), so two Worker processes/threads sharing the same
      # queue file can never both pick up the same job - unlike calling
      # #next_ready followed by #mark_processing as two separate
      # transactions, which leaves a window where both readers still see
      # 'pending' before either writes 'processing'.
      def claim_next!(queue_name: nil)
        @pstore.transaction do
          candidates = @pstore[:jobs].values.select do |job|
            job[:status] == 'pending' && job[:run_at] <= Time.now &&
              (queue_name.nil? || job[:queue_name] == queue_name.to_s)
          end
          job = candidates.min_by { |job| job[:run_at] }
          next nil unless job
          job[:status] = 'processing'
          job.dup
        end
      end

      def mark_completed(id)
        @pstore.transaction { @pstore[:jobs].delete(id) }
      end

      # Records a failed attempt. Reschedules with backoff if attempts
      # remain, otherwise moves the job to the dead-letter table.
      def mark_failed(id, error)
        @pstore.transaction do
          job = @pstore[:jobs][id]
          next unless job
          job[:attempts] += 1
          job[:last_error] = error.to_s
          if job[:attempts] >= job[:max_attempts]
            job[:status] = 'dead'
            @pstore[:dead_letter][id] = job
            @pstore[:jobs].delete(id)
          else
            job[:status] = 'pending'
            job[:run_at] = Time.now + backoff_delay(job[:backoff], job[:attempts])
          end
        end
      end

      def size(queue_name: nil)
        @pstore.transaction(true) do
          @pstore[:jobs].values.count { |job| queue_name.nil? || job[:queue_name] == queue_name.to_s }
        end
      end

      def dead_letter_size
        @pstore.transaction(true) { @pstore[:dead_letter].size }
      end

      def pending_jobs
        @pstore.transaction(true) { @pstore[:jobs].values.map(&:dup) }
      end

      def dead_jobs
        @pstore.transaction(true) { @pstore[:dead_letter].values.map(&:dup) }
      end

      # Re-enqueues a dead-lettered job as a fresh pending job (attempts reset).
      def retry_dead(id)
        @pstore.transaction do
          job = @pstore[:dead_letter].delete(id)
          next nil unless job
          job = job.dup
          job[:status] = 'pending'
          job[:attempts] = 0
          job[:last_error] = nil
          job[:run_at] = Time.now
          @pstore[:jobs][id] = job
          id
        end
      end

      def clear!
        @pstore.transaction do
          @pstore[:jobs] = {}
          @pstore[:dead_letter] = {}
          @pstore[:next_id] = 1
        end
      end

      def backoff_delay(backoff, attempt)
        base = backoff[:base_delay] || 1
        case backoff[:strategy]
        when :exponential then base * (2**(attempt - 1))
        when :linear then base * attempt
        else base
        end
      end
    end
  end
end
