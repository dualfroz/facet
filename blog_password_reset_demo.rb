# End-to-end proof of PasswordResetsController (session 99: Prism::Orm::
# TokenFor, generic ActiveRecord::TokenFor-lite built on MessageVerifier's
# new expires_in:/purpose: envelope) through real HTTP against the actual
# blog app - not just the isolated unit coverage in test_message_verifier.rb
# and test_orm_token_for.rb. Own scratch database directory and own
# in-memory rate limiter store, same pattern as
# blog_remember_sessions_demo.rb, so this never shares data or a throttle
# budget with blog_demo.rb or any other standalone demo script.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'fileutils'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'examples/blog/db/password_reset_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['PRISM_BLOG_DB_DIR'] = SCRATCH_DB_DIR

require_relative 'examples/blog/app'

server = Prism::Server.new(Blog, port: 0).start
port = server.port
puts "blog_password_reset_demo server on port #{port}"
puts '-' * 40

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1] || html[/name="authenticity_token" value="([^"]+)"/, 1]
end

EMAIL = 'forgetful@example.com'
OLD_PASSWORD = 'correct horse battery staple'
NEW_PASSWORD = 'a totally different passphrase'

def sign_in(http, password)
  page = http.get('/session/new')
  cookie = cookie_from(page)
  token = csrf_token_from(page.body)
  body = URI.encode_www_form('user[email]' => EMAIL, 'user[password]' => password, 'authenticity_token' => token)
  http.post('/session', body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
end

Net::HTTP.start('127.0.0.1', port) do |http|
  new_session_page = http.get('/session/new')
  cookie = cookie_from(new_session_page)
  token = csrf_token_from(new_session_page.body)
  signup_body = URI.encode_www_form(
    'user[email]' => EMAIL, 'user[password]' => OLD_PASSWORD, 'user[password_confirmation]' => OLD_PASSWORD,
    'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'
  puts "POST /users (sign up #{EMAIL}) -> #{signup.code}"

  worker = Prism::Jobs::Worker.new(Prism::Jobs.default_queue)
  worker.work_off
  Prism::Mailer.deliveries.clear

  puts '-' * 40
  puts 'requesting a reset link for a real account'
  request_page = http.get('/password_resets/new')
  raise "expected GET /password_resets/new to render, got #{request_page.code}" unless request_page.code == '200'
  request_cookie = cookie_from(request_page)
  request_token = csrf_token_from(request_page.body)

  request_body = URI.encode_www_form('password_reset[email]' => EMAIL, 'authenticity_token' => request_token)
  requested = http.post('/password_resets', request_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                            'Cookie' => request_cookie)
  raise "expected POST /password_resets to redirect, got #{requested.code}" unless requested.code == '302'
  raise 'expected the redirect to land on the sign-in page' unless requested['location'] == '/session/new'
  puts "POST /password_resets (email=#{EMAIL}) -> #{requested.code}, redirected to #{requested['location']}"

  processed = worker.work_off
  raise 'expected exactly one password_reset email to have been delivered' unless Prism::Mailer.deliveries.size == 1
  delivery = Prism::Mailer.deliveries.last
  raise "expected the delivery to go to #{EMAIL}, got #{delivery.to.inspect}" unless delivery.to == [EMAIL]
  reset_path = delivery.html_body[%r{href="http://[^"]*(/password_resets/[^"]+)"}, 1]
  raise 'expected an absolute reset link in the delivered email body' unless reset_path
  reset_token = reset_path[%r{/password_resets/([^/]+)/edit}, 1]
  raise 'expected to be able to pull the raw token out of the mailed reset link' unless reset_token
  puts "worker processed #{processed} job(s); mailed reset link -> #{reset_path}"

  puts '-' * 40
  puts 'requesting a reset link for an email that has NO account - same response, no enumeration oracle'
  unknown_body = URI.encode_www_form('password_reset[email]' => 'nobody@example.com', 'authenticity_token' => request_token)
  unknown = http.post('/password_resets', unknown_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                          'Cookie' => request_cookie)
  raise "expected the SAME 302/location for an unknown email, got #{unknown.code}/#{unknown['location']}" unless
    unknown.code == '302' && unknown['location'] == requested['location']
  worker.work_off
  raise 'expected zero emails for the unknown address' unless Prism::Mailer.deliveries.size == 1
  puts "POST /password_resets (unknown email) -> #{unknown.code}, identical redirect, no email actually sent"

  puts '-' * 40
  puts 'following the real mailed link to set a new password'
  edit_page = http.get(reset_path)
  raise "expected the mailed link to render the reset form, got #{edit_page.code}" unless edit_page.code == '200'
  edit_cookie = cookie_from(edit_page)
  edit_token = csrf_token_from(edit_page.body)
  puts "GET #{reset_path} -> #{edit_page.code}"

  update_body = URI.encode_www_form(
    '_method' => 'PATCH', 'password_reset[password]' => NEW_PASSWORD,
    'password_reset[password_confirmation]' => NEW_PASSWORD, 'authenticity_token' => edit_token
  )
  updated = http.post(reset_path.sub('/edit', ''), update_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                                  'Cookie' => edit_cookie)
  raise "expected the password update to redirect, got #{updated.code}" unless updated.code == '302'
  raise 'expected the update to redirect to sign-in' unless updated['location'] == '/session/new'
  puts "PATCH #{reset_path.sub('/edit', '')} (new password) -> #{updated.code}"

  puts '-' * 40
  puts 'the OLD password no longer authenticates; the NEW one does'
  old_attempt = sign_in(http, OLD_PASSWORD)
  raise "expected the old password to be rejected (422), got #{old_attempt.code}" unless old_attempt.code == '422'
  puts "  POST /session with the OLD password -> #{old_attempt.code} (rejected)"

  new_attempt = sign_in(http, NEW_PASSWORD)
  raise "expected the new password to sign in (302), got #{new_attempt.code}" unless new_attempt.code == '302'
  puts "  POST /session with the NEW password -> #{new_attempt.code} (signed in)"

  puts '-' * 40
  puts 'the SAME reset link cannot be replayed - resetting a password changes password_digest, which is the ' \
       "fingerprint User.generates_token_for(:password_reset) baked into the token, so it's a one-time link " \
       'without any separate "used" column'
  replayed_edit = http.get(reset_path)
  raise "expected the already-used link to redirect away instead of rendering, got #{replayed_edit.code}" unless
    replayed_edit.code == '302'
  raise 'expected the replay to land back on the request-a-new-link page' unless
    replayed_edit['location'] == '/password_resets/new'
  puts "  GET #{reset_path} again -> #{replayed_edit.code}, redirected to #{replayed_edit['location']} (dead link)"

  puts '-' * 40
  puts "checking the password_resets/ip throttle (app.rb, limit 3/60s) - can't be hammered into an email-bomb"
  # The "real account" and "unknown email" requests above already spent 2 of
  # the 3-per-60s budget on this same IP, so only ONE more request here
  # still succeeds before every following one is throttled.
  3.times do |i|
    body = URI.encode_www_form('password_reset[email]' => EMAIL, 'authenticity_token' => request_token)
    attempt = http.post('/password_resets', body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                    'Cookie' => request_cookie)
    expected = i.zero? ? '302' : '429'
    raise "attempt #{i + 1}: expected #{expected}, got #{attempt.code}" unless attempt.code == expected
    raise 'the throttled attempt should carry a Retry-After header' if i == 1 && attempt['retry-after'].nil?
    puts "  attempt #{i + 1}/3 (5th/6th/7th POST /password_resets overall) -> " \
         "#{attempt.code}#{i.zero? ? '' : " (throttled, Retry-After: #{attempt['retry-after']})"}"
  end
end

puts '-' * 40
puts 'blog_password_reset_demo done: forgot-password link is mailed via the real background job queue, resolves ' \
     'through real HTTP to a working password change, the old password stops working and the new one starts, ' \
     'the exact same link cannot be replayed afterwards, an unknown email gets an identical non-committal ' \
     'response, and the request endpoint itself is rate-limited.'
