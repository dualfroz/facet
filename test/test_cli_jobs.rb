require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'
require 'stringio'

class CliJobsEchoJob
  def self.log
    @log ||= []
  end

  def perform(value)
    self.class.log << value
  end
end

class CliJobsAlwaysFailsJob
  def perform
    raise 'boom'
  end
end

class CliJobsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-cli-jobs')
    @cli = Prism::Cli.new(@dir)
    @queue_path = File.join(@dir, 'db', 'jobs.pstore')
    CliJobsEchoJob.log.clear
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def queue
    Prism::Jobs::Queue.new(@queue_path)
  end

  def test_jobs_work_once_drains_ready_jobs_and_returns_a_single_cycle
    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['a'])
    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['b'])

    out = StringIO.new
    cycles = @cli.jobs_work(['--once', '--verbose'], out: out)

    assert_equal 1, cycles
    assert_equal %w[a b], CliJobsEchoJob.log.sort
    assert_equal 0, queue.size
    assert_match(/processed 2 job\(s\)/, out.string)
  end

  def test_jobs_work_respects_custom_file_option
    custom_path = File.join(@dir, 'custom_jobs.pstore')
    Prism::Jobs::Queue.new(custom_path).enqueue(job_class: 'CliJobsEchoJob', args: ['custom'])

    @cli.jobs_work(['--once', '--file=custom_jobs.pstore'])

    assert_equal ['custom'], CliJobsEchoJob.log
    assert_equal 0, Prism::Jobs::Queue.new(custom_path).size
  end

  def test_jobs_work_scopes_to_queue_name
    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['default'])
    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['mailers'], queue_name: 'mailers')

    @cli.jobs_work(['--once', '--queue=mailers'])

    assert_equal ['mailers'], CliJobsEchoJob.log
    assert_equal 1, queue.size
  end

  def test_jobs_work_stops_after_max_cycles_without_sleeping_forever
    cycles = @cli.jobs_work(['--max-cycles=3', '--interval=0'])

    assert_equal 3, cycles
  end

  def test_jobs_work_does_not_crash_on_failing_jobs_and_reports_via_error_output
    queue.enqueue(job_class: 'CliJobsAlwaysFailsJob', args: [], max_attempts: 1)

    _out, err = capture_io { @cli.jobs_work(['--once']) }

    assert_match(/CliJobsAlwaysFailsJob.*failed: boom/, err)
    assert_equal 1, queue.dead_letter_size
  end

  def test_jobs_work_requires_extra_files_before_running
    job_file = File.join(@dir, 'extra_job.rb')
    File.write(job_file, <<~RUBY)
      class CliJobsRequiredJob
        def perform(marker_path)
          File.write(marker_path, 'ran')
        end
      end
    RUBY
    marker_path = File.join(@dir, 'marker.txt')
    queue.enqueue(job_class: 'CliJobsRequiredJob', args: [marker_path])

    @cli.jobs_work(['--once', '--require=extra_job.rb'])

    assert_equal 'ran', File.read(marker_path)
  end

  def test_jobs_work_rejects_unknown_options
    assert_raises(Prism::Cli::UsageError) { @cli.jobs_work(['--bogus']) }
  end

  def test_run_dispatches_jobs_work_through_the_public_cli_entrypoint
    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['via-run'])

    @cli.run(['jobs', 'work', '--once'])

    assert_equal ['via-run'], CliJobsEchoJob.log
  end

  def test_run_rejects_unknown_jobs_subcommand
    assert_raises(Prism::Cli::UsageError) { @cli.run(['jobs', 'bogus']) }
  end

  def test_jobs_work_writes_its_own_pid_while_running_and_removes_it_on_exit
    pidfile = File.join(@dir, 'jobs.pid')

    thread = Thread.new { @cli.jobs_work(['--max-cycles=3', '--interval=0.2', "--pidfile=#{pidfile}"]) }
    sleep 0.05 until File.exist?(pidfile)
    assert_equal Process.pid.to_s, File.read(pidfile).strip

    thread.join

    refute File.exist?(pidfile), 'pidfile should be removed once the worker stops'
  end

  def test_jobs_work_refuses_to_start_while_a_live_process_holds_the_pidfile
    pidfile = File.join(@dir, 'jobs.pid')
    # A genuinely different, currently-alive OS process (a plain child that
    # sleeps) - the same scenario a second real daemon would face, unlike
    # writing our own pid, which the cleanup step would then be entitled to
    # remove because it would truly be ours.
    other_pid = Process.spawn('sleep', '5')
    File.write(pidfile, other_pid.to_s)

    error = assert_raises(Prism::Cli::UsageError) { @cli.jobs_work(['--once', "--pidfile=#{pidfile}"]) }

    assert_match(/already running/, error.message)
    assert_equal other_pid.to_s, File.read(pidfile).strip, "the other process's pidfile must be left untouched"
  ensure
    Process.kill('TERM', other_pid)
    Process.wait(other_pid)
  end

  def test_jobs_work_reclaims_a_stale_pidfile_left_by_a_dead_process
    pidfile = File.join(@dir, 'jobs.pid')
    dead_pid = fork { exit }
    Process.wait(dead_pid)
    File.write(pidfile, dead_pid.to_s)

    queue.enqueue(job_class: 'CliJobsEchoJob', args: ['after-stale-pid'])
    @cli.jobs_work(['--once', "--pidfile=#{pidfile}"])

    assert_equal ['after-stale-pid'], CliJobsEchoJob.log
    refute File.exist?(pidfile)
  end

  # Real end-to-end daemon smoke test: runs `bin/prism jobs work` as its own
  # OS process (no --once, no --max-cycles), lets it poll and drain a job,
  # then sends it SIGINT the same way an operator or init system would and
  # confirms it shuts down cleanly rather than needing to be killed.
  def test_daemon_process_drains_jobs_and_shuts_down_cleanly_on_sigint
    job_file = File.join(@dir, 'daemon_job.rb')
    marker_path = File.join(@dir, 'daemon_marker.txt')
    File.write(job_file, <<~RUBY)
      class CliJobsDaemonJob
        def perform(marker_path)
          File.write(marker_path, 'ran')
        end
      end
    RUBY
    queue.enqueue(job_class: 'CliJobsDaemonJob', args: [marker_path])

    bin = File.expand_path('../bin/prism', __dir__)
    pid = Process.spawn(
      bin, 'jobs', 'work', '--interval=0.05', '--require=daemon_job.rb',
      chdir: @dir, out: File::NULL, err: File::NULL
    )

    deadline = Time.now + 5
    sleep 0.05 until File.exist?(marker_path) || Time.now > deadline
    assert File.exist?(marker_path), 'daemon did not process the job within 5s'
    assert_equal 'ran', File.read(marker_path)

    Process.kill('INT', pid)
    _, status = Process.wait2(pid)
    assert status.success?, "daemon did not exit cleanly after SIGINT (status: #{status})"
  end

  # Real horizontal-scaling scenario: two independent `bin/prism jobs work`
  # daemons (separate OS processes, no pidfile since neither is meant to be
  # "the only one") polling the SAME queue file. Jobs::Queue#claim_next! is
  # already proven race-free at the storage layer (test_jobs_queue.rb spawns
  # 4 bare claimer processes), but that does not by itself prove the CLI
  # daemon loop (poll -> work_off -> sleep -> repeat, plus its own error
  # handling/verbose logging) is safe to run in more than one copy - this
  # drives the actual `bin/prism jobs work` entrypoint twice and checks both
  # that every job runs exactly once AND that work genuinely got split
  # between the two processes rather than one daemon draining the whole
  # queue before the other gets a chance to poll.
  def test_two_real_daemon_processes_share_the_same_queue_without_dropping_or_duplicating_jobs
    job_count = 60
    results_dir = File.join(@dir, 'daemon_results')
    FileUtils.mkdir_p(results_dir)

    job_file = File.join(@dir, 'multi_daemon_job.rb')
    File.write(job_file, <<~RUBY)
      class CliJobsMultiDaemonJob
        def perform(id, results_dir)
          sleep 0.02
          File.write(File.join(results_dir, "job-\#{id}.done"), Process.pid.to_s)
        end
      end
    RUBY

    job_count.times { |i| queue.enqueue(job_class: 'CliJobsMultiDaemonJob', args: [i, results_dir]) }

    bin = File.expand_path('../bin/prism', __dir__)
    pids = 2.times.map do
      Process.spawn(
        bin, 'jobs', 'work', '--interval=0.01', '--require=multi_daemon_job.rb',
        chdir: @dir, out: File::NULL, err: File::NULL
      )
    end

    deadline = Time.now + 10
    sleep 0.05 while queue.size.positive? && Time.now < deadline

    pids.each { |pid| Process.kill('INT', pid) }
    pids.each { |pid| Process.wait2(pid) }

    assert_equal 0, queue.size, 'both daemons together should have drained the whole queue within the deadline'

    result_files = Dir.glob(File.join(results_dir, 'job-*.done'))
    assert_equal job_count, result_files.size, 'every job should have run exactly once (no drops, no duplicates)'
    expected_names = (0...job_count).map { |i| "job-#{i}.done" }.sort
    assert_equal expected_names, result_files.map { |f| File.basename(f) }.sort

    processing_pids = result_files.map { |f| File.read(f).strip }.uniq
    assert_equal pids.map(&:to_s).sort, processing_pids.sort,
                 'both daemon processes should have actually processed jobs, not just one of them'
  end
end
