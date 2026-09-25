require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class JobsQueueTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-jobs-queue')
    @queue = Facet::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_enqueue_returns_an_incrementing_id
    first = @queue.enqueue(job_class: 'X', args: [])
    second = @queue.enqueue(job_class: 'X', args: [])
    assert_equal first + 1, second
  end

  def test_next_ready_returns_the_earliest_due_pending_job
    later = @queue.enqueue(job_class: 'X', args: [1], run_at: Time.now - 5)
    sooner = @queue.enqueue(job_class: 'X', args: [2], run_at: Time.now - 50)
    job = @queue.next_ready
    assert_equal sooner, job[:id]
    refute_equal later, job[:id]
  end

  def test_jobs_scheduled_in_the_future_are_not_ready
    @queue.enqueue(job_class: 'X', args: [], run_at: Time.now + 3600)
    assert_nil @queue.next_ready
  end

  def test_next_ready_respects_queue_name_filter
    @queue.enqueue(job_class: 'X', args: [], queue_name: 'mailers')
    critical_id = @queue.enqueue(job_class: 'X', args: [], queue_name: 'critical')
    job = @queue.next_ready(queue_name: 'critical')
    assert_equal critical_id, job[:id]
  end

  def test_claim_next_returns_the_earliest_due_pending_job_and_marks_it_processing
    later = @queue.enqueue(job_class: 'X', args: [1], run_at: Time.now - 5)
    sooner = @queue.enqueue(job_class: 'X', args: [2], run_at: Time.now - 50)

    job = @queue.claim_next!
    assert_equal sooner, job[:id]
    refute_equal later, job[:id]
    assert_equal 'processing', job[:status]
    assert_equal 'processing', @queue.pending_jobs.find { |j| j[:id] == sooner }[:status]
  end

  def test_claim_next_never_returns_the_same_job_twice
    id = @queue.enqueue(job_class: 'X', args: [])
    first = @queue.claim_next!
    second = @queue.claim_next!
    assert_equal id, first[:id]
    assert_nil second
  end

  def test_claim_next_respects_queue_name_filter
    @queue.enqueue(job_class: 'X', args: [], queue_name: 'mailers')
    critical_id = @queue.enqueue(job_class: 'X', args: [], queue_name: 'critical')
    job = @queue.claim_next!(queue_name: 'critical')
    assert_equal critical_id, job[:id]
  end

  def test_claim_next_is_nil_when_nothing_is_ready
    @queue.enqueue(job_class: 'X', args: [], run_at: Time.now + 3600)
    assert_nil @queue.claim_next!
  end

  def test_claim_next_is_safe_across_real_concurrent_processes
    queue_path = File.join(@dir, 'jobs.pstore')
    job_count = 40
    job_count.times { @queue.enqueue(job_class: 'X', args: []) }

    claims_dir = File.join(@dir, 'claims')
    FileUtils.mkdir_p(claims_dir)
    claimer_script = File.join(@dir, 'claimer.rb')
    File.write(claimer_script, <<~RUBY)
      require 'facet'
      queue = Facet::Jobs::Queue.new(#{queue_path.inspect})
      claims_dir = #{claims_dir.inspect}
      loop do
        job = queue.claim_next!
        break unless job
        File.write(File.join(claims_dir, "\#{job[:id]}.claim"), Process.pid.to_s)
      end
    RUBY

    pids = 4.times.map do
      Process.spawn(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), claimer_script,
                     out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.waitpid(pid) }

    claim_files = Dir.glob(File.join(claims_dir, '*.claim'))
    assert_equal job_count, claim_files.size, 'every enqueued job should have been claimed exactly once'
    assert_equal claim_files.size, claim_files.map { |f| File.basename(f) }.uniq.size,
                 'no job id should have produced more than one claim file'
  end

  def test_mark_completed_removes_the_job
    id = @queue.enqueue(job_class: 'X', args: [])
    @queue.mark_completed(id)
    assert_nil @queue.next_ready
    assert_equal 0, @queue.size
  end

  def test_mark_failed_reschedules_with_exponential_backoff_until_max_attempts
    id = @queue.enqueue(job_class: 'X', args: [], max_attempts: 3, backoff: { strategy: :exponential, base_delay: 2 })
    before = Time.now
    @queue.mark_failed(id, 'boom')
    job = @queue.pending_jobs.first
    assert_equal 1, job[:attempts]
    assert_equal 'pending', job[:status]
    assert_equal 'boom', job[:last_error]
    assert_in_delta (before + 2).to_f, job[:run_at].to_f, 1.0

    @queue.mark_failed(id, 'boom again')
    job = @queue.pending_jobs.first
    assert_equal 2, job[:attempts]
    assert_in_delta (before + 4).to_f, job[:run_at].to_f, 1.0
  end

  def test_mark_failed_dead_letters_after_exhausting_max_attempts
    id = @queue.enqueue(job_class: 'X', args: [], max_attempts: 2)
    @queue.mark_failed(id, 'first failure')
    @queue.mark_failed(id, 'second failure')

    assert_equal 0, @queue.size
    assert_equal 1, @queue.dead_letter_size
    dead = @queue.dead_jobs.first
    assert_equal 'dead', dead[:status]
    assert_equal 'second failure', dead[:last_error]
  end

  def test_retry_dead_moves_a_dead_job_back_to_pending
    id = @queue.enqueue(job_class: 'X', args: [], max_attempts: 1)
    @queue.mark_failed(id, 'fatal')
    assert_equal 1, @queue.dead_letter_size

    @queue.retry_dead(id)
    assert_equal 0, @queue.dead_letter_size
    job = @queue.next_ready
    assert_equal id, job[:id]
    assert_equal 0, job[:attempts]
    assert_nil job[:last_error]
  end

  def test_linear_backoff_grows_by_a_constant_step
    id = @queue.enqueue(job_class: 'X', args: [], max_attempts: 5, backoff: { strategy: :linear, base_delay: 3 })
    before = Time.now
    @queue.mark_failed(id, 'e1')
    job = @queue.pending_jobs.first
    assert_in_delta (before + 3).to_f, job[:run_at].to_f, 1.0

    @queue.mark_failed(id, 'e2')
    job = @queue.pending_jobs.first
    assert_in_delta (before + 6).to_f, job[:run_at].to_f, 1.0
  end

  def test_state_survives_reopening_the_store
    id = @queue.enqueue(job_class: 'PersistedJob', args: [42])
    path = File.join(@dir, 'jobs.pstore')
    reopened = Facet::Jobs::Queue.new(path)
    job = reopened.next_ready
    assert_equal id, job[:id]
    assert_equal [42], job[:args]
  end

  def test_clear_empties_both_tables
    @queue.enqueue(job_class: 'X', args: [])
    dead_id = @queue.enqueue(job_class: 'X', args: [], max_attempts: 1)
    @queue.mark_failed(dead_id, 'boom')

    @queue.clear!
    assert_equal 0, @queue.size
    assert_equal 0, @queue.dead_letter_size
  end
end
