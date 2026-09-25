require 'minitest/autorun'
require 'facet'
require 'support'

class MiddlewareRateLimitingTest < Minitest::Test
  include TestSupport

  def setup
    Facet::RateLimiter.reset!
    @downstream_calls = 0
    downstream = lambda do |_env|
      @downstream_calls += 1
      [200, {}, ['ok']]
    end
    @app = Facet::Middleware::RateLimiting.new(downstream)
  end

  def teardown
    Facet::RateLimiter.reset!
  end

  def request(ip: '1.1.1.1', path: '/login')
    env = env_for('POST', path)
    env['REMOTE_ADDR'] = ip
    @app.call(env)
  end

  def test_requests_under_the_limit_pass_through
    Facet::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times do
      status, = request
      assert_equal 200, status
    end
    assert_equal 2, @downstream_calls
  end

  def test_request_over_the_limit_is_throttled_with_retry_after
    Facet::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times { request }
    status, headers, body = request

    assert_equal 429, status
    assert_equal '60', headers['Retry-After']
    assert_includes body.join, 'Too Many Requests'
    assert_equal 2, @downstream_calls, 'the throttled request must not reach the app'
  end

  def test_throttle_keys_are_independent_per_discriminator_value
    Facet::RateLimiter.throttle('logins/ip', limit: 1, period: 60) { |req| req.env['REMOTE_ADDR'] }

    assert_equal 200, request(ip: '1.1.1.1').first
    assert_equal 200, request(ip: '2.2.2.2').first
    assert_equal 429, request(ip: '1.1.1.1').first
  end

  def test_discriminator_returning_nil_skips_the_rule
    Facet::RateLimiter.throttle('logins/ip', limit: 1, period: 60) { |_req| nil }

    5.times { assert_equal 200, request.first }
  end

  def test_blocklisted_request_is_rejected_with_403_before_reaching_app
    Facet::RateLimiter.blocklist('scanners') { |req| req.path == '/etc/passwd' }

    status, = request(path: '/etc/passwd')
    assert_equal 403, status
    assert_equal 0, @downstream_calls
  end

  def test_safelist_bypasses_an_otherwise_matching_blocklist
    Facet::RateLimiter.blocklist('scanners') { |_req| true }
    Facet::RateLimiter.safelist('trusted') { |req| req.env['REMOTE_ADDR'] == '9.9.9.9' }

    assert_equal 200, request(ip: '9.9.9.9').first
    assert_equal 403, request(ip: '1.1.1.1').first
  end

  def test_track_rule_observes_but_never_blocks
    tracked = []
    Facet::RateLimiter.track('all-logins') { |req| req.env['REMOTE_ADDR'] }
    Facet::RateLimiter.on_notify { |type, name, _req, payload| tracked << [type, name, payload] }

    assert_equal 200, request(ip: '3.3.3.3').first
    assert_equal [[:track, 'all-logins', '3.3.3.3']], tracked
  end

  def test_fail2ban_style_blocklist_bans_after_repeated_offenses
    Facet::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Facet::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    assert_equal 200, request(ip: '5.5.5.5', path: '/etc/passwd').first
    assert_equal 403, request(ip: '5.5.5.5', path: '/etc/passwd').first
    assert_equal 403, request(ip: '5.5.5.5', path: '/harmless').first, 'stays banned without a new offense'
    assert_equal 200, request(ip: '6.6.6.6', path: '/etc/passwd').first, 'other IPs are unaffected'
  end
end
