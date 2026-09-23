$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require_relative 'blog/app'

V1_SECRET = 'blog-demo-encryption-secret-v1'.freeze
V2_SECRET = 'blog-demo-encryption-secret-v2'.freeze
EMAIL = 'rotation@example.com'.freeze
EMAIL_AFTER_UPDATE = 'rotation-updated@example.com'.freeze
PASSWORD = 'correct horse battery staple v2'.freeze
EMAIL_SALT = 'facet-orm-encryption/users/email'.freeze

STRANDED_EMAIL = 'stranded@example.com'.freeze

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

def decrypts_under?(secret, ciphertext)
  key = Facet::MessageEncryptor.derive_key(secret, salt: EMAIL_SALT)
  Facet::Orm::Encryption.decrypt(key, ciphertext)
rescue Facet::Orm::Encryption::Error
  nil
end

phase = ARGV[0]

server = Facet::Server.new(Blog, port: 0).start
port = server.port

case phase
when 'signup'
  Net::HTTP.start('127.0.0.1', port) do |http|
    home = http.get('/')
    cookie = cookie_from(home)
    token = csrf_token_from(home.body)

    body = URI.encode_www_form(
      'user[email]' => EMAIL, 'user[password]' => PASSWORD,
      'user[password_confirmation]' => PASSWORD, 'authenticity_token' => token
    )
    signup = http.post('/users', body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'

    user = User.find_by(email: EMAIL)
    raise 'expected to find the freshly signed-up user by plaintext email under the v1 key' unless user

    row = Facet::Orm.store.find(:users, user.id)
    ciphertext = row['email']
    raise 'expected users.email to be stored encrypted, not plaintext' if ciphertext == EMAIL

    v1_plaintext = decrypts_under?(V1_SECRET, ciphertext)
    raise "expected the row to decrypt under v1, got #{v1_plaintext.inspect}" unless v1_plaintext == EMAIL
    raise 'expected the row NOT to decrypt under v2 yet (never encrypted with it)' if decrypts_under?(V2_SECRET, ciphertext)

    puts 'signup: user provisioned, email ciphertext independently confirmed tied to the v1 secret only'

    stranded_body = URI.encode_www_form(
      'user[email]' => STRANDED_EMAIL, 'user[password]' => PASSWORD,
      'user[password_confirmation]' => PASSWORD, 'authenticity_token' => token
    )
    stranded_signup = http.post('/users', stranded_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected the stranded user's sign-up to redirect, got #{stranded_signup.code}" unless stranded_signup.code == '302'
    raise 'expected to find the stranded user right after signing up' unless User.find_by(email: STRANDED_EMAIL)

    puts 'signup: second user provisioned under v1 too - rotate_and_login will deliberately never touch this one'
  end
when 'rotate_and_login'
  Net::HTTP.start('127.0.0.1', port) do |http|
    home = http.get('/')
    cookie = cookie_from(home)
    token = csrf_token_from(home.body)

    login_body = URI.encode_www_form('user[email]' => EMAIL, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    signed_in = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected sign-in on a still-v1-encrypted row to succeed via previous_keys, got #{signed_in.code}" unless signed_in.code == '302'
    cookie = cookie_from(signed_in)

    edit_page = http.get('/account/edit', 'Cookie' => cookie)
    raise "expected the account edit page to render, got #{edit_page.code}" unless edit_page.code == '200'
    edit_token = csrf_token_from(edit_page.body)

    update_body = URI.encode_www_form('user[email]' => EMAIL_AFTER_UPDATE, '_method' => 'PATCH', 'authenticity_token' => edit_token)
    updated = http.post('/account', update_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected the account update to redirect, got #{updated.code}" unless updated.code == '302'

    user = User.find_by(email: EMAIL_AFTER_UPDATE)
    raise 'expected to find the user by their new plaintext email right after updating it' unless user

    row = Facet::Orm.store.find(:users, user.id)
    ciphertext = row['email']
    v2_plaintext = decrypts_under?(V2_SECRET, ciphertext)
    raise "expected the re-saved row to now decrypt under v2, got #{v2_plaintext.inspect}" unless v2_plaintext == EMAIL_AFTER_UPDATE
    raise 'expected the re-saved row NOT to decrypt under the retired v1 secret anymore' if decrypts_under?(V1_SECRET, ciphertext)

    puts 'rotate_and_login: signed in via the v1 fallback, updated the email, row now migrated onto v2 only'

    raise 'expected the stranded user to still be reachable during the transition window' unless User.find_by(email: STRANDED_EMAIL)
    puts 'rotate_and_login: stranded user deliberately left untouched (still v1-only on disk)'
  end
when 'post_rotation_final'
  Net::HTTP.start('127.0.0.1', port) do |http|
    home = http.get('/')
    cookie = cookie_from(home)
    token = csrf_token_from(home.body)

    login_body = URI.encode_www_form('user[email]' => EMAIL_AFTER_UPDATE, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    signed_in = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected sign-in on the fully-migrated row to succeed with v1 fully retired, got #{signed_in.code}" unless signed_in.code == '302'

    puts 'post_rotation_final: migrated user still signs in with v1 completely retired (no previous_keys configured)'

    stranded_login_body = URI.encode_www_form('user[email]' => STRANDED_EMAIL, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    stranded_login = http.post('/session', stranded_login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected the stranded (never-migrated) user's login to be rejected as invalid credentials, got #{stranded_login.code}" unless stranded_login.code == '422'
    raise 'expected the stranded login rejection page to actually explain why' unless stranded_login.body.include?('Invalid email or password')

    stranded_row = Facet::Orm.store.all(:users).find { |row| decrypts_under?(V1_SECRET, row['email']) == STRANDED_EMAIL }
    raise 'expected the stranded row to still be findable by scanning raw ciphertext under v1' unless stranded_row
    raise 'expected the stranded row to NOT decrypt under v2 (this is the whole point: it was never re-saved)' if decrypts_under?(V2_SECRET, stranded_row['email'])

    puts 'post_rotation_final: stranded (never-migrated) user correctly locked out after full cutover - ' \
         'confirmed the row is genuinely still v1-only on disk, not a false negative'

    stranded_user = User.find(stranded_row['id'])
    begin
      stranded_user.email
      raise 'expected reading .email directly on a fully-retired-key row to raise Encryption::Error, it did not raise at all'
    rescue Facet::Orm::Encryption::Error
      puts 'post_rotation_final: direct .email read on the stranded row raised Encryption::Error as expected ' \
           '(no key left that can decrypt it), unlike the silent find_by miss above'
    end
  end
else
  raise "unknown phase #{phase.inspect} (expected signup, rotate_and_login, or post_rotation_final)"
end

server.stop
