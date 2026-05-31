# Runs ONE phase of the rate-limiter persistence lifecycle against
# examples/blog, over a real HTTP request cycle. Always invoked as a brand
# new `ruby` process by blog_rate_limit_persistence_demo.rb (never required
# directly) - the whole point is that Prism::RateLimiter.store is now a
# Prism::RateLimiter::PStoreStore (see examples/blog/app.rb), so a ban or a
# throttle window tripped by one process must still be in effect for a
# completely fresh process that never made any of the earlier requests
# itself, exactly like a real deploy restarting the app mid-attack.
#
# Covers both throttles examples/blog declares against the same
# PStoreStore file (logins/ip and signups/ip) - session 85 only proved
# logins/ip durability; signups/ip shares the store but was never
# exercised across a real restart of its own.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require_relative 'examples/blog/app'

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

phase = ARGV[0]

server = Prism::Server.new(Blog, port: 0).start
port = server.port

Net::HTTP.start('127.0.0.1', port) do |http|
  home = http.get('/')
  cookie = cookie_from(home)
  token = csrf_token_from(home.body)
  login_body = URI.encode_www_form(
    'user[email]' => 'nobody@example.com', 'user[password]' => 'wrong password', 'authenticity_token' => token
  )
  # Mismatched confirmation is a validation failure (422) that never
  # touches the uniqueness index, so the same body can be POSTed
  # repeatedly without tripping User's unique-email constraint instead of
  # the throttle we actually want to exercise.
  signup_body = URI.encode_www_form(
    'user[email]' => 'nobody@example.com', 'user[password]' => 'secret123',
    'user[password_confirmation]' => 'does not match', 'authenticity_token' => token
  )

  case phase
  when 'trip'
    # logins/ip is throttle(limit: 5, period: 60) in examples/blog/app.rb -
    # attempts 1..5 are the credentials check itself (422, wrong password),
    # attempt 6 never reaches the controller at all.
    5.times do |i|
      attempt = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
      raise "trip attempt #{i + 1}: expected 422 (invalid credentials), got #{attempt.code}" unless attempt.code == '422'
    end
    sixth = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "trip attempt 6: expected 429 (throttled), got #{sixth.code}" unless sixth.code == '429'
    puts 'trip: 5 attempts allowed through to the controller, the 6th throttled with 429 - process now exiting'
  when 'confirm_still_blocked'
    # Brand new process, brand new Ruby-level RateLimiter::Rule registry
    # (throttles are re-declared by requiring app.rb again) and a brand new
    # in-memory window if the store were MemoryStore - the ONLY way this
    # first request can already be 429, with zero attempts made by THIS
    # process, is if the PStoreStore file from the 'trip' phase is still
    # being read.
    immediate = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    unless immediate.code == '429'
      raise "expected the very first request from a fresh process to already be throttled (durable state), got #{immediate.code}"
    end
    raise 'the still-blocked response should carry a Retry-After header' if immediate['retry-after'].nil?
    puts 'confirm_still_blocked: a fresh process inherited the ban/window from the previous process via PStoreStore - ' \
         "first request already 429, Retry-After=#{immediate['retry-after']}"
  when 'trip_signup'
    # signups/ip is throttle(limit: 3, period: 60) in examples/blog/app.rb -
    # attempts 1..3 are the validation check itself (422, password
    # mismatch), attempt 4 never reaches the controller at all.
    3.times do |i|
      attempt = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
      raise "trip_signup attempt #{i + 1}: expected 422 (mismatched confirmation), got #{attempt.code}" unless attempt.code == '422'
    end
    fourth = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "trip_signup attempt 4: expected 429 (throttled), got #{fourth.code}" unless fourth.code == '429'
    puts 'trip_signup: 3 attempts allowed through to the controller, the 4th throttled with 429 - process now exiting'
  when 'confirm_signup_still_blocked'
    # Same durability claim as confirm_still_blocked above, for the
    # independent signups/ip throttle rule.
    immediate = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    unless immediate.code == '429'
      raise "expected the very first signup request from a fresh process to already be throttled (durable state), got #{immediate.code}"
    end
    raise 'the still-blocked response should carry a Retry-After header' if immediate['retry-after'].nil?
    puts 'confirm_signup_still_blocked: a fresh process inherited the signups/ip window from the previous process via ' \
         "PStoreStore - first request already 429, Retry-After=#{immediate['retry-after']}"
  else
    raise "unknown phase #{phase.inspect} (expected trip, confirm_still_blocked, trip_signup or confirm_signup_still_blocked)"
  end
end

server.stop
