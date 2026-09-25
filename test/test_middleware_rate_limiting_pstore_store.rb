require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'
require 'support'

class MiddlewareRateLimitingPStoreStoreTest < Minitest::Test
  include TestSupport

  def setup
    @original_store = Facet::RateLimiter.store
    @dir = Dir.mktmpdir('facet-rate-limit-pstore-')
    @path = File.join(@dir, 'rate_limits.pstore')
    Facet::RateLimiter.store = Facet::RateLimiter::PStoreStore.new(@path)
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
    Facet::RateLimiter.store = @original_store
    FileUtils.remove_entry(@dir)
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

  def test_blocklisted_request_is_rejected_with_403_before_reaching_app
    Facet::RateLimiter.blocklist('scanners') { |req| req.path == '/etc/passwd' }

    status, = request(path: '/etc/passwd')
    assert_equal 403, status
    assert_equal 0, @downstream_calls
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
  end

  def test_throttle_state_survives_a_simulated_process_restart
    Facet::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times { assert_equal 200, request.first }

    Facet::RateLimiter.store = Facet::RateLimiter::PStoreStore.new(@path)
    Facet::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    status, headers, = request
    assert_equal 429, status, 'the window counter must have been read back from disk, not reset to zero'
    assert_equal '60', headers['Retry-After']
  end

  def test_ban_state_survives_a_simulated_process_restart
    Facet::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Facet::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    assert_equal 200, request(ip: '7.7.7.7', path: '/etc/passwd').first
    assert_equal 403, request(ip: '7.7.7.7', path: '/etc/passwd').first

    Facet::RateLimiter.store = Facet::RateLimiter::PStoreStore.new(@path)
    Facet::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Facet::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    status, = request(ip: '7.7.7.7', path: '/harmless')
    assert_equal 403, status, 'the ban must have been read back from disk, not lost with the old store object'
  end
end
