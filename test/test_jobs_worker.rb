require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class RecordingJob
  def self.log
    @log ||= []
  end

  def perform(value)
    self.class.log << value
  end
end

class FlakyJob
  def self.attempts
    @attempts ||= 0
  end

  def self.reset!
    @attempts = 0
  end

  def perform
    self.class.instance_variable_set(:@attempts, self.class.attempts + 1)
    raise "not yet (attempt #{self.class.attempts})" if self.class.attempts < 3
  end
end

class AlwaysFailsJob
  def perform
    raise 'nope'
  end
end

class WorkerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-jobs-worker')
    @queue = Facet::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    RecordingJob.log.clear
    FlakyJob.reset!
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_work_off_performs_every_ready_job
    @queue.enqueue(job_class: 'RecordingJob', args: ['a'])
    @queue.enqueue(job_class: 'RecordingJob', args: ['b'])

    processed = Facet::Jobs::Worker.new(@queue).work_off

    assert_equal 2, processed
    assert_equal %w[a b], RecordingJob.log.sort
    assert_equal 0, @queue.size
  end

  def test_work_off_does_not_touch_jobs_scheduled_in_the_future
    @queue.enqueue(job_class: 'RecordingJob', args: ['now'])
    @queue.enqueue(job_class: 'RecordingJob', args: ['later'], run_at: Time.now + 3600)

    processed = Facet::Jobs::Worker.new(@queue).work_off

    assert_equal 1, processed
    assert_equal ['now'], RecordingJob.log
    assert_equal 1, @queue.size
  end

  def test_failing_job_is_retried_and_eventually_succeeds
    @queue.enqueue(job_class: 'FlakyJob', args: [])
    worker = Facet::Jobs::Worker.new(@queue)

    worker.work_off
    assert_equal 0, worker.work_off, 'retry is backed off into the future, not immediately ready'
    force_all_due

    worker.work_off
    force_all_due
    worker.work_off

    assert_equal 0, @queue.size
    assert_equal 3, FlakyJob.attempts
  end

  def test_job_that_always_fails_is_dead_lettered_after_max_attempts
    @queue.enqueue(job_class: 'AlwaysFailsJob', args: [], max_attempts: 2)
    worker = Facet::Jobs::Worker.new(@queue)

    worker.work_off
    force_all_due
    worker.work_off

    assert_equal 0, @queue.size
    assert_equal 1, @queue.dead_letter_size
    assert_match(/nope/, @queue.dead_jobs.first[:last_error])
  end

  def test_error_handler_is_invoked_with_the_exception_and_job
    seen = []
    @queue.enqueue(job_class: 'AlwaysFailsJob', args: [], max_attempts: 5)
    worker = Facet::Jobs::Worker.new(@queue, error_handler: ->(error, job) { seen << [error.message, job[:job_class]] })

    worker.work_off

    assert_equal [['nope', 'AlwaysFailsJob']], seen
  end

  def test_work_off_can_be_scoped_to_a_single_queue_name
    @queue.enqueue(job_class: 'RecordingJob', args: ['default-queue'])
    @queue.enqueue(job_class: 'RecordingJob', args: ['mailers-queue'], queue_name: 'mailers')

    processed = Facet::Jobs::Worker.new(@queue, queue_name: 'mailers').work_off

    assert_equal 1, processed
    assert_equal ['mailers-queue'], RecordingJob.log
    assert_equal 1, @queue.size
  end

  def test_process_publishes_perform_job_instrumentation_event
    @queue.enqueue(job_class: 'RecordingJob', args: ['c'], queue_name: 'mailers')
    events = []
    subscriber = Facet::Instrumentation.subscribe('perform_job.facet') { |event| events << event }

    Facet::Jobs::Worker.new(@queue, queue_name: 'mailers').work_off

    assert_equal 1, events.size
    assert_equal 'RecordingJob', events.first.payload[:job_class]
    assert_equal 'mailers', events.first.payload[:queue_name]
    assert_equal 'completed', events.first.payload[:status]
    assert_kind_of Float, events.first.duration
  ensure
    Facet::Instrumentation.unsubscribe(subscriber)
  end

  def test_process_publishes_instrumentation_event_with_exception_on_failure
    @queue.enqueue(job_class: 'AlwaysFailsJob', args: [], max_attempts: 5)
    events = []
    subscriber = Facet::Instrumentation.subscribe('perform_job.facet') { |event| events << event }

    Facet::Jobs::Worker.new(@queue).work_off

    assert_equal 1, events.size
    assert_nil events.first.payload[:status]
    assert_equal 'nope', events.first.payload[:exception][1]
  ensure
    Facet::Instrumentation.unsubscribe(subscriber)
  end

  private

  def force_all_due
    pstore = @queue.instance_variable_get(:@pstore)
    pstore.transaction { pstore[:jobs].each_value { |job| job[:run_at] = Time.now - 1 } }
  end
end
