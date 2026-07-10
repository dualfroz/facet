require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'
require 'support'

# Session 85 wired Prism::RateLimiter::PStoreStore into examples/blog and
# proved durability with a real two-process demo (blog_rate_limit_
# persistence_demo.rb), but test_middleware_rate_limiting.rb only ever
# exercises the default MemoryStore - so Middleware::RateLimiting itself
# was never unit-tested against the durable store it actually ships with
# in the example app. This file closes that gap: same middleware, same
# rule DSL, but every counter/ban lives in a PStoreStore file on disk, and
# the durability claim itself is proven in-process by dropping the store
# object and opening a brand new one against the same path (the cheapest
# faithful stand-in for "the process restarted").
class MiddlewareRateLimitingPStoreStoreTest < Minitest::Test
  include TestSupport

  def setup
    # Minitest runs every test method from every loaded file in one
    # randomized order within a single process, so Prism::RateLimiter's
    # module-level store must be put back exactly as found - otherwise a
    # later test in test_middleware_rate_limiting.rb or
    # test_rate_limiter.rb would inherit this file's PStoreStore pointed
    # at a tmpdir this test already deleted, and blow up with ENOENT.
    @original_store = Prism::RateLimiter.store
    @dir = Dir.mktmpdir('prism-rate-limit-pstore-')
    @path = File.join(@dir, 'rate_limits.pstore')
    # Assign the new store BEFORE calling reset! - reset! resets whatever
    # store is currently set, and it must not touch @original_store's file.
    Prism::RateLimiter.store = Prism::RateLimiter::PStoreStore.new(@path)
    Prism::RateLimiter.reset!
    @downstream_calls = 0
    downstream = lambda do |_env|
      @downstream_calls += 1
      [200, {}, ['ok']]
    end
    @app = Prism::Middleware::RateLimiting.new(downstream)
  end

  def teardown
    Prism::RateLimiter.reset!
    Prism::RateLimiter.store = @original_store
    FileUtils.remove_entry(@dir)
  end

  def request(ip: '1.1.1.1', path: '/login')
    env = env_for('POST', path)
    env['REMOTE_ADDR'] = ip
    @app.call(env)
  end

  def test_requests_under_the_limit_pass_through
    Prism::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times do
      status, = request
      assert_equal 200, status
    end
    assert_equal 2, @downstream_calls
  end

  def test_request_over_the_limit_is_throttled_with_retry_after
    Prism::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times { request }
    status, headers, body = request

    assert_equal 429, status
    assert_equal '60', headers['Retry-After']
    assert_includes body.join, 'Too Many Requests'
    assert_equal 2, @downstream_calls, 'the throttled request must not reach the app'
  end

  def test_blocklisted_request_is_rejected_with_403_before_reaching_app
    Prism::RateLimiter.blocklist('scanners') { |req| req.path == '/etc/passwd' }

    status, = request(path: '/etc/passwd')
    assert_equal 403, status
    assert_equal 0, @downstream_calls
  end

  def test_fail2ban_style_blocklist_bans_after_repeated_offenses
    Prism::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Prism::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    assert_equal 200, request(ip: '5.5.5.5', path: '/etc/passwd').first
    assert_equal 403, request(ip: '5.5.5.5', path: '/etc/passwd').first
    assert_equal 403, request(ip: '5.5.5.5', path: '/harmless').first, 'stays banned without a new offense'
  end

  def test_throttle_state_survives_a_simulated_process_restart
    Prism::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    2.times { assert_equal 200, request.first }

    # Simulate the process dying and a brand new one booting: a fresh
    # PStoreStore instance against the same file, with no in-memory state
    # inherited from the object above. The rule DSL (throttles/blocklists)
    # is process-local config re-declared on boot, exactly like
    # examples/blog/app.rb re-declares its throttles every start; only the
    # counters/bans themselves need to survive on disk.
    Prism::RateLimiter.store = Prism::RateLimiter::PStoreStore.new(@path)
    Prism::RateLimiter.throttle('logins/ip', limit: 2, period: 60) { |req| req.env['REMOTE_ADDR'] }

    status, headers, = request
    assert_equal 429, status, 'the window counter must have been read back from disk, not reset to zero'
    assert_equal '60', headers['Retry-After']
  end

  def test_ban_state_survives_a_simulated_process_restart
    Prism::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Prism::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    # maxretry: 2 - the 1st offense only records a strike (still let
    # through), the 2nd offense crosses the threshold and this same
    # request is already rejected.
    assert_equal 200, request(ip: '7.7.7.7', path: '/etc/passwd').first
    assert_equal 403, request(ip: '7.7.7.7', path: '/etc/passwd').first

    Prism::RateLimiter.store = Prism::RateLimiter::PStoreStore.new(@path)
    Prism::RateLimiter.blocklist('fail2ban pentesters') do |req|
      Prism::RateLimiter.fail2ban_filter(req.env['REMOTE_ADDR'], maxretry: 2, findtime: 60, bantime: 300) do
        req.path.include?('/etc/passwd')
      end
    end

    status, = request(ip: '7.7.7.7', path: '/harmless')
    assert_equal 403, status, 'the ban must have been read back from disk, not lost with the old store object'
  end
end
