require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class OrmPessimisticTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-pessimistic')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:counters, %w[id value])

    counter_class = Class.new(Prism::Orm::Model) { table_name :counters }
    counter_class.store = @store
    Object.const_set(:Counter, counter_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Counter) if Object.const_defined?(:Counter)
  end

  def test_lock_bang_raises_on_a_record_that_was_never_saved
    counter = Counter.new(value: 0)
    assert_raises(Prism::Orm::Pessimistic::UnpersistedRecordError) { counter.lock! }
  end

  def test_lock_bang_raises_on_a_record_with_unsaved_changes
    counter = Counter.create!(value: 0)
    counter.value = 5
    assert_raises(Prism::Orm::Pessimistic::DirtyRecordError) { counter.lock! }
  end

  def test_lock_bang_reloads_data_written_by_another_handle_in_the_meantime
    counter = Counter.create!(value: 0)
    Counter.find(counter.id).update!(value: 41)

    counter.lock!

    assert_equal 41, counter.value
  end

  def test_lock_bang_returns_self
    counter = Counter.create!(value: 0)
    assert_same counter, counter.lock!
  end

  def test_with_lock_yields_the_record_with_freshly_reloaded_data
    counter = Counter.create!(value: 0)
    Counter.find(counter.id).update!(value: 9)

    yielded = nil
    counter.with_lock { |c| yielded = c }

    assert_same counter, yielded
    assert_equal 9, counter.value
  end

  def test_with_lock_commits_a_write_made_inside_the_block
    counter = Counter.create!(value: 1)
    counter.with_lock { |c| c.update!(value: c.value + 1) }
    assert_equal 2, Counter.find(counter.id).value
  end

  def test_with_lock_rolls_back_a_write_made_inside_the_block_on_exception
    counter = Counter.create!(value: 1)
    assert_raises(RuntimeError) do
      counter.with_lock do |c|
        c.update!(value: 99)
        raise 'boom'
      end
    end
    assert_equal 1, Counter.find(counter.id).value
  end

  def test_with_lock_nests_inside_an_already_open_transaction_without_deadlocking
    counter = Counter.create!(value: 1)
    Counter.transaction do
      counter.with_lock { |c| c.update!(value: c.value + 1) }
    end
    assert_equal 2, Counter.find(counter.id).value
  end

  # Everything below forks real child OS processes sharing nothing but the
  # PStore file on disk - Store#within_transaction opens a brand new file
  # handle and takes a real File::LOCK_EX/LOCK_SH on it for every single
  # transaction (stdlib pstore.rb, not something this codebase controls),
  # so this is the same cross-process guarantee two independent `prism`
  # server processes pointed at the same database file would get, not a
  # simulation of it via threads. `exit!` (not `exit`) is required in every
  # forked child: minitest/autorun installs an at_exit hook, and a plain
  # `exit` would let the child fall into that hook and re-run the entire
  # suite a second time from inside the fork.
  def test_two_processes_updating_without_a_lock_lose_an_update
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    counter = Counter.create!(value: 0)
    a_read, a_wrote_read_signal = IO.pipe
    b_read, b_wrote_read_signal = IO.pipe

    # Two pipes force the full ordering a lost update needs: A reads, THEN
    # B reads (while the value is still whatever A saw, because A is
    # blocked waiting on B before it writes anything), THEN both write back
    # "their own read + 1" as two independent transactions. Only the READS
    # are ordered here - deliberately NOT the writes, since a real lost
    # update does not care which write lands last, only that both were
    # computed from the same stale value.
    pid_a = Process.fork do
      a_read.close
      b_wrote_read_signal.close
      value = Counter.find(counter.id).value
      a_wrote_read_signal.write('r')
      a_wrote_read_signal.close
      b_read.read(1)
      b_read.close
      Counter.find(counter.id).update!(value: value + 1)
      exit!(0)
    end

    pid_b = Process.fork do
      a_wrote_read_signal.close
      b_read.close
      a_read.read(1)
      a_read.close
      value = Counter.find(counter.id).value
      b_wrote_read_signal.write('r')
      b_wrote_read_signal.close
      Counter.find(counter.id).update!(value: value + 1)
      exit!(0)
    end

    [a_read, a_wrote_read_signal, b_read, b_wrote_read_signal].each(&:close)
    Process.waitpid(pid_a)
    Process.waitpid(pid_b)

    # Both processes read 0 (forced ordering above only sequences the
    # reads), so both independently write 1 back - the second write just
    # clobbers the first with the exact same value, silently losing A's
    # increment no matter which of the two writes lands last.
    assert_equal 1, Counter.find(counter.id).value
  end

  def test_two_processes_incrementing_through_with_lock_never_lose_an_update
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    counter = Counter.create!(value: 0)
    increments_per_process = 5

    pids = Array.new(2) do
      Process.fork do
        increments_per_process.times do
          Counter.find(counter.id).with_lock { |c| c.update!(value: c.value + 1) }
        end
        exit!(0)
      end
    end

    pids.each { |pid| Process.waitpid(pid) }

    assert_equal 2 * increments_per_process, Counter.find(counter.id).value
  end
end
