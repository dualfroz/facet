require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class CliJobsConcurrentDaemonsTest < Minitest::Test
  DAEMON_COUNT = 5
  JOB_COUNT = 60

  def setup
    @dir = Dir.mktmpdir('facet-cli-jobs-concurrent')
    @queue_path = File.join(@dir, 'db', 'jobs.pstore')
    @claims_dir = File.join(@dir, 'claims')
    @pids_dir = File.join(@dir, 'pids')
    FileUtils.mkdir_p(@claims_dir)
    FileUtils.mkdir_p(@pids_dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_concurrent_daemons_each_process_every_job_exactly_once_with_no_lost_or_duplicated_work
    queue = Facet::Jobs::Queue.new(@queue_path)
    markers = JOB_COUNT.times.map(&:to_s)
    markers.each { |marker| queue.enqueue(job_class: 'CliJobsConcurrentClaimJob', args: [marker]) }

    job_class_file = File.join(@dir, 'claim_job.rb')
    File.write(job_class_file, <<~RUBY)
      class CliJobsConcurrentClaimJob
        def perform(marker)
          sleep(rand * 0.01)
          File.write(File.join(#{@claims_dir.inspect}, "\#{marker}.claim"), Process.pid.to_s)
        end
      end
    RUBY

    daemon_script = File.join(@dir, 'daemon.rb')
    File.write(daemon_script, <<~RUBY)
      require 'facet'
      cli = Facet::Cli.new(#{@dir.inspect})
      cli.jobs_work(
        ['--once', '--file=#{@queue_path}', '--require=#{job_class_file}', "--pidfile=\#{ARGV[0]}"],
        out: File.open(File::NULL, 'w')
      )
    RUBY

    pids = DAEMON_COUNT.times.map do |i|
      pidfile = File.join(@pids_dir, "worker-#{i}.pid")
      Process.spawn(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), daemon_script, pidfile,
                    out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.waitpid(pid) }

    claim_files = Dir.glob(File.join(@claims_dir, '*.claim'))
    claimed_markers = claim_files.map { |f| File.basename(f, '.claim') }

    assert_equal JOB_COUNT, claim_files.size, 'every enqueued job should have been performed exactly once'
    assert_equal markers.sort, claimed_markers.sort, 'the exact set of enqueued jobs should have been claimed, no more, no less'
    assert_equal claimed_markers.size, claimed_markers.uniq.size, 'no job should have been performed twice by two different daemons'

    assert_equal 0, queue.size, 'the queue should be fully drained'
    assert_equal 0, queue.dead_letter_size, 'no job should have failed'
    assert_empty Dir.glob(File.join(@pids_dir, '*.pid')), 'every daemon should have removed its own pidfile on exit'
  end
end
