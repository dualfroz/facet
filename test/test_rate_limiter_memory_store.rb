require 'minitest/autorun'
require 'prism'

class RateLimiterMemoryStoreTest < Minitest::Test
  def setup
    @store = Prism::RateLimiter::MemoryStore.new
  end

  def test_count_increments_within_the_same_window
    assert_equal 1, @store.count('ip:1', 60)
    assert_equal 2, @store.count('ip:1', 60)
    assert_equal 3, @store.count('ip:1', 60)
  end

  def test_count_is_independent_per_key
    assert_equal 1, @store.count('ip:1', 60)
    assert_equal 1, @store.count('ip:2', 60)
  end

  def test_count_resets_after_the_window_elapses
    assert_equal 1, @store.count('ip:1', 0.05)
    assert_equal 2, @store.count('ip:1', 0.05)
    sleep 0.08
    assert_equal 1, @store.count('ip:1', 0.05)
  end

  def test_banned_is_false_when_never_banned
    refute @store.banned?('ip:1')
  end

  def test_ban_makes_banned_true_until_it_expires
    @store.ban!('ip:1', 0.05)
    assert @store.banned?('ip:1')
    sleep 0.08
    refute @store.banned?('ip:1')
  end

  def test_reset_clears_windows_and_bans
    @store.count('ip:1', 60)
    @store.ban!('ip:2', 60)
    @store.reset!
    assert_equal 1, @store.count('ip:1', 60)
    refute @store.banned?('ip:2')
  end

  def test_concurrent_increments_do_not_lose_updates
    threads = Array.new(20) do
      Thread.new { 100.times { @store.count('shared', 60) } }
    end
    threads.each(&:join)
    assert_equal 2001, @store.count('shared', 60)
  end
end
