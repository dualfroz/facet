require 'minitest/autorun'
require 'prism'

class RateLimiterDslTest < Minitest::Test
  def setup
    Prism::RateLimiter.reset!
  end

  def teardown
    Prism::RateLimiter.reset!
  end

  def test_throttle_registers_a_named_rule
    Prism::RateLimiter.throttle('logins/ip', limit: 5, period: 60) { |req| req }
    rule = Prism::RateLimiter.throttles.fetch('logins/ip')
    assert_equal 5, rule.limit
    assert_equal 60, rule.period
  end

  def test_blocklist_safelist_and_track_registries_are_independent
    Prism::RateLimiter.blocklist('bad-actors') { |_req| true }
    Prism::RateLimiter.safelist('internal') { |_req| false }
    Prism::RateLimiter.track('all-requests') { |_req| true }

    assert_equal %w[bad-actors], Prism::RateLimiter.blocklists.keys
    assert_equal %w[internal], Prism::RateLimiter.safelists.keys
    assert_equal %w[all-requests], Prism::RateLimiter.tracks.keys
  end

  def test_reset_clears_every_registry_and_the_store
    Prism::RateLimiter.throttle('t', limit: 1, period: 60) { |_req| 'k' }
    Prism::RateLimiter.store.count('t:k', 60)

    Prism::RateLimiter.reset!

    assert_empty Prism::RateLimiter.throttles
    assert_equal 1, Prism::RateLimiter.store.count('t:k', 60)
  end

  def test_on_notify_receives_type_name_request_and_payload
    seen = []
    Prism::RateLimiter.on_notify { |type, name, _request, payload| seen << [type, name, payload] }
    Prism::RateLimiter.notify(:throttle, 'logins/ip', :fake_request, '1.2.3.4')
    assert_equal [[:throttle, 'logins/ip', '1.2.3.4']], seen
  end

  def test_fail2ban_filter_allows_offenses_below_the_threshold
    3.times.each do |i|
      blocked = Prism::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { true }
      assert_equal(i == 2, blocked)
    end
  end

  def test_fail2ban_filter_ignores_non_offenses
    5.times do
      refute Prism::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { false }
    end
  end

  def test_fail2ban_filter_keeps_blocking_once_banned_even_without_a_new_offense
    3.times { Prism::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { true } }
    assert Prism::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { false }
  end
end
