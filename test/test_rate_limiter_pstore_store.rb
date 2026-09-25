require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class RateLimiterPStoreStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-rate-limiter')
    @path = File.join(@dir, 'nested', 'rate_limits.pstore')
    @store = Facet::RateLimiter::PStoreStore.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_creates_parent_directories
    assert File.directory?(File.dirname(@path))
  end

  def test_count_increments_within_the_same_window
    assert_equal 1, @store.count('ip:1', 60)
    assert_equal 2, @store.count('ip:1', 60)
  end

  def test_count_resets_after_the_window_elapses
    assert_equal 1, @store.count('ip:1', 0.05)
    sleep 0.08
    assert_equal 1, @store.count('ip:1', 0.05)
  end

  def test_ban_makes_banned_true_until_it_expires
    @store.ban!('ip:1', 0.05)
    assert @store.banned?('ip:1')
    sleep 0.08
    refute @store.banned?('ip:1')
  end

  def test_state_survives_reopening_the_same_file
    @store.count('ip:1', 60)
    @store.count('ip:1', 60)
    @store.ban!('ip:2', 60)

    reopened = Facet::RateLimiter::PStoreStore.new(@path)
    assert_equal 3, reopened.count('ip:1', 60)
    assert reopened.banned?('ip:2')
  end

  def test_reset_clears_windows_and_bans
    @store.count('ip:1', 60)
    @store.ban!('ip:2', 60)
    @store.reset!
    assert_equal 1, @store.count('ip:1', 60)
    refute @store.banned?('ip:2')
  end

  def test_count_is_safe_across_real_concurrent_processes
    store_path = File.join(@dir, 'shared.pstore')
    process_count = 4
    increments_per_process = 25

    counter_script = File.join(@dir, 'counter.rb')
    File.write(counter_script, <<~RUBY)
      require 'facet'
      store = Facet::RateLimiter::PStoreStore.new(#{store_path.inspect})
      results = Array.new(#{increments_per_process}) { store.count('shared-key', 3600) }
      File.write(File.join(#{@dir.inspect}, "\#{Process.pid}.result"), results.join(','))
    RUBY

    pids = process_count.times.map do
      Process.spawn(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), counter_script,
                     out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.waitpid(pid) }

    observed = pids.flat_map do |pid|
      path = File.join(@dir, "#{pid}.result")
      File.read(path).split(',').map(&:to_i)
    end

    expected_total = process_count * increments_per_process
    assert_equal expected_total, observed.size
    assert_equal (1..expected_total).to_a.sort, observed.sort,
                 'every value from 1..total should appear exactly once - a lost update would ' \
                 'produce a duplicate and leave a gap'

    final_store = Facet::RateLimiter::PStoreStore.new(store_path)
    assert_equal expected_total + 1, final_store.count('shared-key', 3600)
  end
end
