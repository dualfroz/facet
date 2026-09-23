$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require 'fileutils'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'blog/db/remember_sessions_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['FACET_BLOG_DB_DIR'] = SCRATCH_DB_DIR

require_relative 'blog/app'

server = Facet::Server.new(Blog, port: 0).start
port = server.port
puts "blog_remember_sessions_demo server on port #{port}"
puts '-' * 40

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def cookie_value_from(response, name)
  lines = response.get_fields('set-cookie') || []
  line = lines.find { |l| l.start_with?("#{name}=") }
  line&.split(';')&.first
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

EMAIL = 'devices@example.com'
PASSWORD = 'correct horse battery staple'

def sign_in_device(http, label, user_agent:)
  page = http.get('/session/new', 'User-Agent' => user_agent)
  device_cookie = cookie_from(page)
  device_token = csrf_token_from(page.body)
  body = URI.encode_www_form(
    'user[email]' => EMAIL, 'user[password]' => PASSWORD, 'user[remember_me]' => '1',
    'authenticity_token' => device_token
  )
  signed_in = http.post('/session', body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                           'Cookie' => device_cookie, 'User-Agent' => user_agent)
  raise "expected #{label} to sign in, got #{signed_in.code}" unless signed_in.code == '302'
  fresh_session_cookie = cookie_from(signed_in)
  session_cookie = fresh_session_cookie.empty? ? device_cookie : fresh_session_cookie
  remember_cookie = cookie_value_from(signed_in, 'remember_session_token')
  raise "expected #{label} to get its own remember_session_token cookie" unless remember_cookie
  puts "  #{label} signed in (remember_me=1) -> #{signed_in.code}, own remember-me cookie set"
  [session_cookie, remember_cookie]
end

def other_session_ids(http, session_cookie)
  page = http.get('/login_sessions', 'Cookie' => session_cookie)
  raise "expected GET /login_sessions to succeed, got #{page.code}" unless page.code == '200'
  page.body.scan(/class="login-session" id="login-session-(\d+)"/).flatten.map(&:to_i)
end

def alive?(http, remember_cookie)
  http.get('/login_sessions', 'Cookie' => remember_cookie).code == '200'
end

Net::HTTP.start('127.0.0.1', port) do |http|
  new_session_page = http.get('/session/new')
  cookie = cookie_from(new_session_page)
  token = csrf_token_from(new_session_page.body)

  signup_body = URI.encode_www_form(
    'user[email]' => EMAIL, 'user[password]' => PASSWORD, 'user[password_confirmation]' => PASSWORD,
    'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'
  puts "POST /users (sign up #{EMAIL}) -> #{signup.code}"

  puts '-' * 40
  puts 'three independent devices sign in with remember_me=1 - exactly at max_remember_sessions: 3, ' \
       'nothing should be pruned yet'
  _p_session, p_remember = sign_in_device(http, 'device P', user_agent: 'DeviceP-Desktop/1.0')
  _q_session, q_remember = sign_in_device(http, 'device Q', user_agent: 'DeviceQ-Mobile/1.0')
  r_session, r_remember = sign_in_device(http, 'device R', user_agent: 'DeviceR-Tablet/1.0')

  at_limit_others = other_session_ids(http, r_session)
  unless at_limit_others.size == 2
    raise "expected exactly 2 OTHER remembered devices (P and Q) alongside R itself at the limit, " \
          "got #{at_limit_others.inspect}"
  end
  puts "GET /login_sessions as device R -> 200, itself plus #{at_limit_others.size} others (P, Q) - " \
       'at the limit, no pruning yet'
  raise 'expected device P to still be alive exactly at the limit' unless alive?(http, p_remember)
  raise 'expected device Q to still be alive exactly at the limit' unless alive?(http, q_remember)
  puts '  both P and Q still authenticate via their remember-me cookie alone'

  puts '-' * 40
  puts 'a FOURTH device signs in, pushing the account one over max_remember_sessions: 3 - ' \
       'Facet::Authenticatable#prune_oldest_login_sessions should destroy the OLDEST row (device P)'
  s_session, s_remember = sign_in_device(http, 'device S', user_agent: 'DeviceS-Laptop/1.0')

  over_limit_others = other_session_ids(http, s_session)
  unless over_limit_others.size == 2
    raise "expected pruning to keep the count at 2 OTHER devices (Q and R) alongside S itself, " \
          "got #{over_limit_others.inspect}"
  end
  puts "GET /login_sessions as device S -> 200, itself plus #{over_limit_others.size} others - " \
       'still exactly at the limit after the 4th sign-in, not 4'

  raise 'expected device P (the oldest) to have been pruned' if alive?(http, p_remember)
  puts "  device P's remember-me cookie is now dead (its LoginSession row was destroyed) -> " \
       'redirected to sign-in instead of 200'

  raise 'expected device Q to survive the prune (only the OLDEST row is destroyed)' unless alive?(http, q_remember)
  raise 'expected device R to survive the prune' unless alive?(http, r_remember)
  raise 'expected the newly created device S to be alive' unless alive?(http, s_remember)
  puts '  devices Q, R and S (everything except the pruned oldest one) all still authenticate via their own ' \
       'remember-me cookie'

  pruned_id = (at_limit_others - over_limit_others).first
  raise 'expected exactly one id to have dropped out of the device list after the prune' unless pruned_id
  raise "expected R's own device list to also no longer show the pruned id" if other_session_ids(http, r_session).include?(pruned_id)
  puts "  device R's own list agrees: login-session-#{pruned_id} (device P) is gone from EVERY account member's view, " \
       'not just S\'s'
end

puts '-' * 40
puts 'blog_remember_sessions_demo done: max_remember_sessions: 3 stays at exactly 3 remembered devices per ' \
     'account - signing in a 4th prunes the single oldest row (never the newest, never more than one), and ' \
     'every survivor keeps authenticating on its own remember-me cookie afterwards.'
