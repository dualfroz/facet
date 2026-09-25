require 'minitest/autorun'
require 'facet'

class RateLimiterDslTest < Minitest::Test
  def setup
    Facet::RateLimiter.reset!
  end

  def teardown
    Facet::RateLimiter.reset!
  end

  def test_throttle_registers_a_named_rule
    Facet::RateLimiter.throttle('logins/ip', limit: 5, period: 60) { |req| req }
    rule = Facet::RateLimiter.throttles.fetch('logins/ip')
    assert_equal 5, rule.limit
    assert_equal 60, rule.period
  end

  def test_blocklist_safelist_and_track_registries_are_independent
    Facet::RateLimiter.blocklist('bad-actors') { |_req| true }
    Facet::RateLimiter.safelist('internal') { |_req| false }
    Facet::RateLimiter.track('all-requests') { |_req| true }

    assert_equal %w[bad-actors], Facet::RateLimiter.blocklists.keys
    assert_equal %w[internal], Facet::RateLimiter.safelists.keys
    assert_equal %w[all-requests], Facet::RateLimiter.tracks.keys
  end

  def test_reset_clears_every_registry_and_the_store
    Facet::RateLimiter.throttle('t', limit: 1, period: 60) { |_req| 'k' }
    Facet::RateLimiter.store.count('t:k', 60)

    Facet::RateLimiter.reset!

    assert_empty Facet::RateLimiter.throttles
    assert_equal 1, Facet::RateLimiter.store.count('t:k', 60)
  end

  def test_on_notify_receives_type_name_request_and_payload
    seen = []
    Facet::RateLimiter.on_notify { |type, name, _request, payload| seen << [type, name, payload] }
    Facet::RateLimiter.notify(:throttle, 'logins/ip', :fake_request, '1.2.3.4')
    assert_equal [[:throttle, 'logins/ip', '1.2.3.4']], seen
  end

  def test_fail2ban_filter_allows_offenses_below_the_threshold
    3.times.each do |i|
      blocked = Facet::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { true }
      assert_equal(i == 2, blocked)
    end
  end

  def test_fail2ban_filter_ignores_non_offenses
    5.times do
      refute Facet::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { false }
    end
  end

  def test_fail2ban_filter_keeps_blocking_once_banned_even_without_a_new_offense
    3.times { Facet::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { true } }
    assert Facet::RateLimiter.fail2ban_filter('1.2.3.4', maxretry: 3, findtime: 60, bantime: 300) { false }
  end
end
