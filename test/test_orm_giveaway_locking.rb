require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

# Fast, deterministic, in-suite complement to blog_giveaway_demo.rb/
# blog_giveaway_worker.rb (examples/blog's real "hard-capped giveaway"
# feature, ClaimsController#create) - same read-count-then-decide-then-
# write shape as Prism::Orm::Pessimistic's own counter tests
# (test_orm_pessimistic.rb) and the acts_as_list swap-under-lock fix, but
# for a "claim one of N limited slots" critical section specifically:
# proves first that the race is real without a held lock (two racing
# processes can BOTH believe they won the same last slot), then that
# Model#with_lock rules it out entirely under genuinely concurrent OS
# processes, not just threads.
class OrmGiveawayLockingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-giveaway-locking')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:giveaways, %w[id slots claimed])

    giveaway_class = Class.new(Prism::Orm::Model) { table_name :giveaways }
    giveaway_class.store = @store
    Object.const_set(:Giveaway, giveaway_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Giveaway) if Object.const_defined?(:Giveaway)
  end

  # Same rationale as test_orm_pessimistic.rb's own fork-based tests: real
  # child OS processes sharing nothing but the PStore file on disk, so
  # this is the same cross-process guarantee independent `prism` server
  # processes pointed at the same database would get, not a simulation of
  # it via threads. `exit!` (not `exit`), same reason as
  # test_orm_pessimistic.rb: skip minitest/autorun's at_exit hook.
  def test_claiming_without_a_lock_lets_two_racing_processes_both_win_the_last_slot
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    giveaway = Giveaway.create!(slots: 1, claimed: 0)
    a_result = File.join(@dir, 'a_outcome')
    b_result = File.join(@dir, 'b_outcome')
    a_read, a_wrote_read_signal = IO.pipe
    b_read, b_wrote_read_signal = IO.pipe

    # Two pipes force the exact ordering an oversell needs: A reads the
    # not-yet-claimed slot, THEN B reads it too (while it is still
    # unclaimed, because A is blocked waiting on B before it writes
    # anything back), THEN both independently decide "still free" and
    # both write - each computing its own outcome from the SAME stale
    # read, exactly like ClaimsController#create's giveaway_sold_out?
    # check would without post.with_lock around it.
    pid_a = Process.fork do
      a_read.close
      b_wrote_read_signal.close
      record = Giveaway.find(giveaway.id)
      a_wrote_read_signal.write('r')
      a_wrote_read_signal.close
      b_read.read(1)
      b_read.close
      outcome = record.claimed < record.slots ? :claimed : :sold_out
      Giveaway.find(giveaway.id).update!(claimed: record.claimed + 1) if outcome == :claimed
      File.write(a_result, outcome.to_s)
      exit!(0)
    end

    pid_b = Process.fork do
      a_wrote_read_signal.close
      b_read.close
      a_read.read(1)
      a_read.close
      record = Giveaway.find(giveaway.id)
      b_wrote_read_signal.write('r')
      b_wrote_read_signal.close
      outcome = record.claimed < record.slots ? :claimed : :sold_out
      Giveaway.find(giveaway.id).update!(claimed: record.claimed + 1) if outcome == :claimed
      File.write(b_result, outcome.to_s)
      exit!(0)
    end

    [a_read, a_wrote_read_signal, b_read, b_wrote_read_signal].each(&:close)
    Process.waitpid(pid_a)
    Process.waitpid(pid_b)

    # The actual harm a real giveaway cares about: both processes decided
    # THEY were the one who got the last slot - two winners for one prize -
    # even though the persisted counter itself only ever reflects a single
    # increment (same lost-update shape as Store#increment_counter's own
    # unlocked callers), which would make the bug look survivable if this
    # test only checked Giveaway#claimed afterward instead of what each
    # racing process actually told its caller.
    assert_equal 'claimed', File.read(a_result)
    assert_equal 'claimed', File.read(b_result)
  end

  def test_claiming_through_with_lock_never_oversells_under_real_concurrent_processes
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    slots = 3
    racers = 5
    giveaway = Giveaway.create!(slots: slots, claimed: 0)

    pids = racers.times.map do |i|
      result_path = File.join(@dir, "outcome_#{i}")
      Process.fork do
        outcome = nil
        Giveaway.find(giveaway.id).with_lock do |record|
          outcome = record.claimed < record.slots ? :claimed : :sold_out
          record.update!(claimed: record.claimed + 1) if outcome == :claimed
        end
        File.write(result_path, outcome.to_s)
        exit!(0)
      end
    end

    pids.each { |pid| Process.waitpid(pid) }

    outcomes = racers.times.map { |i| File.read(File.join(@dir, "outcome_#{i}")) }
    assert_equal slots, outcomes.count('claimed')
    assert_equal racers - slots, outcomes.count('sold_out')
    assert_equal slots, Giveaway.find(giveaway.id).claimed
  end
end
