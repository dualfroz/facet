# End-to-end proof of EmailConfirmationsController (this session's business
# use of Prism::Orm::TokenFor, already generic and tested in isolation by
# test_orm_token_for.rb/test_message_verifier.rb since sessions 100/101) -
# through real HTTP against the actual blog app, not just User#confirmed?
# read in a REPL. Own scratch database directory and own rate limiter
# store, same pattern as blog_password_reset_demo.rb, so this never shares
# data or a throttle budget with blog_demo.rb or any other standalone demo.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'fileutils'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'examples/blog/db/email_confirmation_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['PRISM_BLOG_DB_DIR'] = SCRATCH_DB_DIR

require_relative 'examples/blog/app'

server = Prism::Server.new(Blog, port: 0).start
port = server.port
puts "blog_email_confirmation_demo server on port #{port}"
puts '-' * 40

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1] || html[/name="authenticity_token" value="([^"]+)"/, 1]
end

def confirmation_path_from(delivery)
  path = delivery.html_body[%r{href="http://[^"]*(/email_confirmations/[^"]+)"}, 1]
  raise 'expected an absolute confirmation link in the delivered email body' unless path
  path
end

CAROL_EMAIL = 'carol@example.com'
CAROL_NEW_EMAIL = 'carol.new@example.com'
CAROL_PASSWORD = 'correct horse battery staple'
worker = Prism::Jobs::Worker.new(Prism::Jobs.default_queue)

Net::HTTP.start('127.0.0.1', port) do |http|
  new_session_page = http.get('/session/new')
  cookie = cookie_from(new_session_page)
  token = csrf_token_from(new_session_page.body)
  signup_body = URI.encode_www_form(
    'user[email]' => CAROL_EMAIL, 'user[password]' => CAROL_PASSWORD,
    'user[password_confirmation]' => CAROL_PASSWORD, 'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'
  cookie = cookie_from(signup) unless cookie_from(signup).empty?
  puts "POST /users (sign up #{CAROL_EMAIL}) -> #{signup.code}"

  worker.work_off
  raise 'expected exactly 2 emails from signup (welcome + confirmation instructions)' unless Prism::Mailer.deliveries.size == 2
  raise 'expected the freshly signed-up account to start out unconfirmed' if User.find_by(email: CAROL_EMAIL).confirmed?
  puts "worker drained signup's 2 emails; User#confirmed? -> false right after signup"

  puts '-' * 40
  puts 'requesting a fresh confirmation link via the resend form (own account is unconfirmed) - POST #1/3 of the ' \
       'email_confirmations/ip budget'
  Prism::Mailer.deliveries.clear
  resend_page = http.get('/email_confirmations/new')
  raise "expected GET /email_confirmations/new to render, got #{resend_page.code}" unless resend_page.code == '200'
  resend_cookie = cookie_from(resend_page)
  resend_token = csrf_token_from(resend_page.body)

  resend_body = URI.encode_www_form('email_confirmation[email]' => CAROL_EMAIL, 'authenticity_token' => resend_token)
  resent = http.post('/email_confirmations', resend_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                            'Cookie' => resend_cookie)
  raise "expected POST /email_confirmations to redirect, got #{resent.code}" unless resent.code == '302'
  raise 'expected the redirect to land on the sign-in page' unless resent['location'] == '/session/new'
  puts "POST /email_confirmations (email=#{CAROL_EMAIL}) -> #{resent.code}, redirected to #{resent['location']}"

  worker.work_off
  raise 'expected exactly one confirmation email from the resend' unless Prism::Mailer.deliveries.size == 1
  delivery = Prism::Mailer.deliveries.last
  raise "expected the delivery to go to #{CAROL_EMAIL}, got #{delivery.to.inspect}" unless delivery.to == [CAROL_EMAIL]
  confirmation_path = confirmation_path_from(delivery)
  # The path segment itself is URL-encoded (the token's own base64 padding
  # bytes need escaping in an href) - decode it before comparing against a
  # freshly minted token below, which comes back from Ruby unencoded.
  mailed_token = URI.decode_www_form_component(confirmation_path.split('/').last)
  puts "worker processed the resend job; mailed confirmation link -> #{confirmation_path}"

  puts '-' * 40
  puts 'the envelope is a pure function of id+fingerprint(email)+purpose with no expires_in set (unlike ' \
       'password_reset), so minting a token for the SAME still-unconfirmed account a second time - here done ' \
       'directly through the model, not by spending another throttled HTTP request - is byte-identical to the ' \
       'one that was just mailed, not a fresh, different-looking token'
  regenerated_token = User.find_by(email: CAROL_EMAIL).generate_token_for(:email_confirmation)
  raise 'expected re-minting the token for the same unconfirmed account to be byte-identical' unless regenerated_token == mailed_token
  puts '  User#generate_token_for(:email_confirmation) again -> identical token bytes'

  puts '-' * 40
  puts 'following the mailed link confirms the account'
  confirm_page = http.get(confirmation_path)
  raise "expected the confirmation link to redirect, got #{confirm_page.code}" unless confirm_page.code == '302'
  raise 'expected confirming to redirect to the homepage' unless confirm_page['location'] == '/'
  puts "GET #{confirmation_path} -> #{confirm_page.code} Location=#{confirm_page['location']}"
  raise 'expected User#confirmed? to flip to true' unless User.find_by(email: CAROL_EMAIL).confirmed?
  puts '  User#confirmed? -> true'

  puts '-' * 40
  puts 'revisiting the EXACT SAME confirmation link a second time is harmless (302 to the homepage again) - the ' \
       'defining difference from PasswordResetsController: that token fingerprints password_digest, which the ' \
       'reset action itself changes, so a reset link dies after one use; this token fingerprints email, which ' \
       'confirming does not touch, so the same link keeps confirming (a no-op past the first time) instead of dying'
  replayed_confirm = http.get(confirmation_path)
  raise "expected the replayed link to still redirect to '/', got #{replayed_confirm.code}/#{replayed_confirm['location']}" \
    unless replayed_confirm.code == '302' && replayed_confirm['location'] == '/'
  puts "  GET #{confirmation_path} again -> #{replayed_confirm.code} Location=#{replayed_confirm['location']} " \
       '(still alive, not a dead link)'

  puts '-' * 40
  puts "resending for #{CAROL_EMAIL} once ALREADY confirmed sends no mail at all - same enumeration-safe redirect " \
       'either way, exactly like PasswordResetsController#create for an unknown address, but the branch here is ' \
       '"already confirmed" instead of "no such account". POST #2/3 of the budget.'
  no_mail_resend_body = URI.encode_www_form('email_confirmation[email]' => CAROL_EMAIL, 'authenticity_token' => resend_token)
  no_mail_resend = http.post('/email_confirmations', no_mail_resend_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                                           'Cookie' => resend_cookie)
  raise "expected the resend-while-confirmed to still redirect, got #{no_mail_resend.code}" unless no_mail_resend.code == '302'
  worker.work_off
  raise 'expected zero emails for an already-confirmed resend' unless Prism::Mailer.deliveries.size == 1
  puts "POST /email_confirmations (email=#{CAROL_EMAIL}, already confirmed) -> #{no_mail_resend.code}, no new mail sent"

  puts '-' * 40
  puts 'requesting a resend for an email that has NO account - identical response, no enumeration oracle. ' \
       'POST #3/3 of the budget.'
  unknown_body = URI.encode_www_form('email_confirmation[email]' => 'nobody@example.com', 'authenticity_token' => resend_token)
  unknown = http.post('/email_confirmations', unknown_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                              'Cookie' => resend_cookie)
  raise "expected the SAME 302/location for an unknown email, got #{unknown.code}/#{unknown['location']}" unless
    unknown.code == '302' && unknown['location'] == resent['location']
  worker.work_off
  raise 'expected zero emails for the unknown address' unless Prism::Mailer.deliveries.size == 1
  puts "POST /email_confirmations (unknown email) -> #{unknown.code}, identical redirect, no email actually sent"

  puts '-' * 40
  puts 'a garbage/unknown token redirects to the resend form instead of confirming anything (a GET, not throttled)'
  garbage = http.get('/email_confirmations/not-a-real-token')
  raise "expected a garbage token to redirect, got #{garbage.code}" unless garbage.code == '302'
  raise 'expected a garbage token to redirect to the resend form' unless garbage['location'] == '/email_confirmations/new'
  puts "GET /email_confirmations/not-a-real-token -> #{garbage.code} Location=#{garbage['location']}"

  puts '-' * 40
  puts "checking the email_confirmations/ip throttle (app.rb, limit 3/60s) - can't be hammered into an email-bomb. " \
       'The 3 POSTs above (real resend, already-confirmed resend, unknown-email resend) already spent the whole ' \
       'budget, so this 4th one from the same IP must be rejected outright.'
  throttled = http.post('/email_confirmations', unknown_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                                'Cookie' => resend_cookie)
  raise "expected this 4th request to be throttled (429), got #{throttled.code}" unless throttled.code == '429'
  raise 'the throttled attempt should carry a Retry-After header' if throttled['retry-after'].nil?
  puts "  POST /email_confirmations (4th, budget exhausted) -> #{throttled.code} (throttled, Retry-After: #{throttled['retry-after']})"

  puts '-' * 40
  puts 'reconfirmable: signing in and changing to a new address un-confirms the account (Devise-style ' \
       'reconfirmable), and the OLD confirmation link stops working even though it is otherwise still well-formed'
  sign_in_page = http.get('/session/new')
  sign_in_cookie = cookie_from(sign_in_page)
  sign_in_token = csrf_token_from(sign_in_page.body)
  sign_in_body = URI.encode_www_form('user[email]' => CAROL_EMAIL, 'user[password]' => CAROL_PASSWORD,
                                      'authenticity_token' => sign_in_token)
  signed_in = http.post('/session', sign_in_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                    'Cookie' => sign_in_cookie)
  raise "expected sign-in to succeed, got #{signed_in.code}" unless signed_in.code == '302'
  session_cookie = cookie_from(signed_in)
  session_cookie = sign_in_cookie if session_cookie.empty?
  puts "POST /session (#{CAROL_EMAIL}) -> #{signed_in.code}, signed in"

  edit_account_page = http.get('/account/edit', 'Cookie' => session_cookie)
  raise "expected GET /account/edit to render, got #{edit_account_page.code}" unless edit_account_page.code == '200'
  account_cookie = cookie_from(edit_account_page)
  account_cookie = session_cookie if account_cookie.empty?
  account_token = csrf_token_from(edit_account_page.body)

  change_email_body = URI.encode_www_form('_method' => 'PATCH', 'user[email]' => CAROL_NEW_EMAIL,
                                           'authenticity_token' => account_token)
  changed = http.post('/account', change_email_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                       'Cookie' => account_cookie)
  raise "expected the email change to redirect, got #{changed.code}" unless changed.code == '302'
  puts "PATCH /account (email -> #{CAROL_NEW_EMAIL}) -> #{changed.code}"
  raise 'expected changing email to un-confirm the account' if User.find_by(email: CAROL_NEW_EMAIL).confirmed?
  puts '  User#confirmed? -> false again (email changed, reset_confirmation_if_email_changed fired)'

  stale_confirm = http.get(confirmation_path)
  raise "expected the OLD confirmation link to now be rejected, got #{stale_confirm.code}/#{stale_confirm['location']}" \
    unless stale_confirm.code == '302' && stale_confirm['location'] == '/email_confirmations/new'
  puts "  GET #{confirmation_path} (minted for the OLD address) -> #{stale_confirm.code} " \
       "Location=#{stale_confirm['location']} (fingerprint mismatch: token carries the old email, account now " \
       'holds the new one)'

  # Minted directly through the model, not via another throttled POST
  # /email_confirmations - the budget above is already spent for this demo
  # process' one IP, and minting is exactly what that endpoint does
  # internally anyway (see EmailConfirmationsController#create).
  fresh_token = User.find_by(email: CAROL_NEW_EMAIL).generate_token_for(:email_confirmation)
  fresh_path = "/email_confirmations/#{fresh_token}"
  fresh_confirm = http.get(fresh_path)
  raise "expected a token minted for the NEW address to confirm, got #{fresh_confirm.code}" \
    unless fresh_confirm.code == '302' && fresh_confirm['location'] == '/'
  raise 'expected User#confirmed? to be true again under the new address' unless User.find_by(email: CAROL_NEW_EMAIL).confirmed?
  puts "  GET #{fresh_path} (minted directly for #{CAROL_NEW_EMAIL}) -> #{fresh_confirm.code}, confirmed again"
end

puts '-' * 40
puts 'blog_email_confirmation_demo done: confirmation instructions are mailed via the real background job queue ' \
     'right after sign-up, the resend form is enumeration-safe (no mail for an already-confirmed or unknown ' \
     'address) and throttled, the mailed link confirms the account and stays valid on repeat visits (unlike a ' \
     'password reset link), and changing to a new address un-confirms the account and invalidates the OLD ' \
     "address's token while a freshly minted one for the new address still works."
