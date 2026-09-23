$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require_relative 'blog/app'

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

phase = ARGV[0]

server = Facet::Server.new(Blog, port: 0).start
port = server.port

Net::HTTP.start('127.0.0.1', port) do |http|
  home = http.get('/')
  cookie = cookie_from(home)
  token = csrf_token_from(home.body)
  login_body = URI.encode_www_form(
    'user[email]' => 'nobody@example.com', 'user[password]' => 'wrong password', 'authenticity_token' => token
  )
  signup_body = URI.encode_www_form(
    'user[email]' => 'nobody@example.com', 'user[password]' => 'secret123',
    'user[password_confirmation]' => 'does not match', 'authenticity_token' => token
  )

  case phase
  when 'trip'
    5.times do |i|
      attempt = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
      raise "trip attempt #{i + 1}: expected 422 (invalid credentials), got #{attempt.code}" unless attempt.code == '422'
    end
    sixth = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "trip attempt 6: expected 429 (throttled), got #{sixth.code}" unless sixth.code == '429'
    puts 'trip: 5 attempts allowed through to the controller, the 6th throttled with 429 - process now exiting'
  when 'confirm_still_blocked'
    immediate = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    unless immediate.code == '429'
      raise "expected the very first request from a fresh process to already be throttled (durable state), got #{immediate.code}"
    end
    raise 'the still-blocked response should carry a Retry-After header' if immediate['retry-after'].nil?
    puts 'confirm_still_blocked: a fresh process inherited the ban/window from the previous process via PStoreStore - ' \
         "first request already 429, Retry-After=#{immediate['retry-after']}"
  when 'trip_signup'
    3.times do |i|
      attempt = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
      raise "trip_signup attempt #{i + 1}: expected 422 (mismatched confirmation), got #{attempt.code}" unless attempt.code == '422'
    end
    fourth = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "trip_signup attempt 4: expected 429 (throttled), got #{fourth.code}" unless fourth.code == '429'
    puts 'trip_signup: 3 attempts allowed through to the controller, the 4th throttled with 429 - process now exiting'
  when 'confirm_signup_still_blocked'
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
