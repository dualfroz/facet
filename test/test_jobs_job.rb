require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class WelcomeEmailJob < Prism::Jobs::Job
  queue_as :mailers
  retry_on max_attempts: 7, backoff: :linear, base_delay: 5

  def self.sent_to
    @sent_to ||= []
  end

  def perform(user_id)
    self.class.sent_to << user_id
  end
end

class PlainJob < Prism::Jobs::Job
  def self.ran
    @ran ||= false
  end

  def self.reset!
    @ran = false
  end

  def perform
    self.class.instance_variable_set(:@ran, true)
  end
end

class JobTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-jobs-job')
    @queue = Prism::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    Prism::Jobs.default_queue = @queue
    WelcomeEmailJob.sent_to.clear
    PlainJob.reset!
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_perform_now_runs_synchronously_without_touching_the_queue
    WelcomeEmailJob.perform_now(101)

    assert_equal [101], WelcomeEmailJob.sent_to
    assert_equal 0, @queue.size
  end

  def test_perform_later_enqueues_with_the_declared_queue_and_retry_policy
    WelcomeEmailJob.perform_later(202)

    job = @queue.pending_jobs.first
    assert_equal 'WelcomeEmailJob', job[:job_class]
    assert_equal [202], job[:args]
    assert_equal 'mailers', job[:queue_name]
    assert_equal 7, job[:max_attempts]
    assert_equal({ strategy: :linear, base_delay: 5 }, job[:backoff])
    assert_empty WelcomeEmailJob.sent_to
  end

  def test_perform_later_can_override_the_declared_queue
    WelcomeEmailJob.perform_later(303, queue: 'urgent_mailers')

    assert_equal 'urgent_mailers', @queue.pending_jobs.first[:queue_name]
  end

  def test_perform_later_honors_an_explicit_run_at
    future = Time.now + 3600
    WelcomeEmailJob.perform_later(404, run_at: future)

    assert_nil @queue.next_ready
    job = @queue.pending_jobs.first
    assert_in_delta future.to_f, job[:run_at].to_f, 1.0
  end

  def test_job_without_queue_as_or_retry_on_uses_sane_defaults
    PlainJob.perform_later

    job = @queue.pending_jobs.first
    assert_equal 'default', job[:queue_name]
    assert_equal 5, job[:max_attempts]
  end

  def test_enqueued_jobs_actually_run_through_a_worker
    WelcomeEmailJob.perform_later(505)
    Prism::Jobs::Worker.new(@queue).work_off

    assert_equal [505], WelcomeEmailJob.sent_to
  end
end
