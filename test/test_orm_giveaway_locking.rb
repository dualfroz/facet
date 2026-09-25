require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class OrmGiveawayLockingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-giveaway-locking')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:giveaways, %w[id slots claimed])

    giveaway_class = Class.new(Facet::Orm::Model) { table_name :giveaways }
    giveaway_class.store = @store
    Object.const_set(:Giveaway, giveaway_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Giveaway) if Object.const_defined?(:Giveaway)
  end

  def test_claiming_without_a_lock_lets_two_racing_processes_both_win_the_last_slot
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    giveaway = Giveaway.create!(slots: 1, claimed: 0)
    a_result = File.join(@dir, 'a_outcome')
    b_result = File.join(@dir, 'b_outcome')
    a_read, a_wrote_read_signal = IO.pipe
    b_read, b_wrote_read_signal = IO.pipe

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
