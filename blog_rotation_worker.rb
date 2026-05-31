# Runs ONE phase of the encryption key rotation lifecycle against
# examples/blog, over a real HTTP request cycle. Always invoked as a brand
# new `ruby` process by blog_rotation_demo.rb (never required directly) -
# Prism::Orm::Encryption derives and caches each model's encryption key
# once per class per process (see encryption_key_for), so genuinely retiring
# an old secret and adopting a new one needs a fresh process with fresh ENV,
# not just a different in-process config call.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require_relative 'examples/blog/app'

V1_SECRET = 'blog-demo-encryption-secret-v1'.freeze
V2_SECRET = 'blog-demo-encryption-secret-v2'.freeze
EMAIL = 'rotation@example.com'.freeze
EMAIL_AFTER_UPDATE = 'rotation-updated@example.com'.freeze
PASSWORD = 'correct horse battery staple v2'.freeze
EMAIL_SALT = 'prism-orm-encryption/users/email'.freeze

# A second row provisioned alongside the first but NEVER re-saved during
# the transition window (no login, no account update in 'rotate_and_login')
# - the realistic case of a row an operator forgot about, or a user who
# simply never signs back in before the cutover deadline. Same password
# for both so post_rotation_final's failing login attempt is unambiguously
# about the ciphertext, not a typo'd credential.
STRANDED_EMAIL = 'stranded@example.com'.freeze

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

# Independent of anything User/Encryption has cached in this process -
# derives a key straight from a raw secret and tries to decrypt with it,
# so a phase can prove exactly WHICH secret a given row's ciphertext is
# really tied to, not just that "some configured key" happens to work.
def decrypts_under?(secret, ciphertext)
  key = Prism::MessageEncryptor.derive_key(secret, salt: EMAIL_SALT)
  Prism::Orm::Encryption.decrypt(key, ciphertext)
rescue Prism::Orm::Encryption::Error
  nil
end

phase = ARGV[0]

server = Prism::Server.new(Blog, port: 0).start
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

    row = Prism::Orm.store.find(:users, user.id)
    ciphertext = row['email']
    raise 'expected users.email to be stored encrypted, not plaintext' if ciphertext == EMAIL

    v1_plaintext = decrypts_under?(V1_SECRET, ciphertext)
    raise "expected the row to decrypt under v1, got #{v1_plaintext.inspect}" unless v1_plaintext == EMAIL
    raise 'expected the row NOT to decrypt under v2 yet (never encrypted with it)' if decrypts_under?(V2_SECRET, ciphertext)

    puts 'signup: user provisioned, email ciphertext independently confirmed tied to the v1 secret only'

    # Second row, provisioned the same way, that 'rotate_and_login' will
    # deliberately leave untouched - the row this whole scenario is about.
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

    # The app is now running with v2 as the CURRENT key and v1 only as a
    # previous_keys fallback - this row has never been touched since
    # 'signup' wrote it under v1, so finding it at all here is the real
    # proof that Encryption.decrypt_with_rotation's fallback (and
    # encrypt_for_query's multi-candidate IN-list) both work over a real
    # request cycle, not just against a fixture in a unit test.
    login_body = URI.encode_www_form('user[email]' => EMAIL, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    signed_in = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected sign-in on a still-v1-encrypted row to succeed via previous_keys, got #{signed_in.code}" unless signed_in.code == '302'
    cookie = cookie_from(signed_in)

    edit_page = http.get('/account/edit', 'Cookie' => cookie)
    raise "expected the account edit page to render, got #{edit_page.code}" unless edit_page.code == '200'
    edit_token = csrf_token_from(edit_page.body)

    # Changing the email is what actually forces a fresh Encryption.encrypt
    # call (the setter's no-op guard only skips re-encrypting when the
    # plaintext is unchanged) - the natural way a real user's row gets
    # migrated onto the new key, exactly as Prism::Orm::Encryption's own
    # comments describe ("any row that gets explicitly re-saved").
    update_body = URI.encode_www_form('user[email]' => EMAIL_AFTER_UPDATE, '_method' => 'PATCH', 'authenticity_token' => edit_token)
    updated = http.post('/account', update_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected the account update to redirect, got #{updated.code}" unless updated.code == '302'

    user = User.find_by(email: EMAIL_AFTER_UPDATE)
    raise 'expected to find the user by their new plaintext email right after updating it' unless user

    row = Prism::Orm.store.find(:users, user.id)
    ciphertext = row['email']
    v2_plaintext = decrypts_under?(V2_SECRET, ciphertext)
    raise "expected the re-saved row to now decrypt under v2, got #{v2_plaintext.inspect}" unless v2_plaintext == EMAIL_AFTER_UPDATE
    raise 'expected the re-saved row NOT to decrypt under the retired v1 secret anymore' if decrypts_under?(V1_SECRET, ciphertext)

    puts 'rotate_and_login: signed in via the v1 fallback, updated the email, row now migrated onto v2 only'

    # Deliberately NOT touched here: the stranded user's row stays exactly
    # as 'signup' left it, still encrypted under v1 only, still findable
    # right now only because this phase still carries v1 in previous_keys.
    raise 'expected the stranded user to still be reachable during the transition window' unless User.find_by(email: STRANDED_EMAIL)
    puts 'rotate_and_login: stranded user deliberately left untouched (still v1-only on disk)'
  end
when 'post_rotation_final'
  Net::HTTP.start('127.0.0.1', port) do |http|
    home = http.get('/')
    cookie = cookie_from(home)
    token = csrf_token_from(home.body)

    # v1 has been fully retired (PRISM_BLOG_ENCRYPTION_PREVIOUS_SECRETS is
    # unset for this phase) - the migrated row from 'rotate_and_login' must
    # still authenticate on v2 alone, proving the cutover is safe to
    # complete once every row has actually been re-saved.
    login_body = URI.encode_www_form('user[email]' => EMAIL_AFTER_UPDATE, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    signed_in = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected sign-in on the fully-migrated row to succeed with v1 fully retired, got #{signed_in.code}" unless signed_in.code == '302'

    puts 'post_rotation_final: migrated user still signs in with v1 completely retired (no previous_keys configured)'

    # The risk this whole scenario documents: cutting v1 over BEFORE every
    # row has actually been re-saved locks out whoever was never migrated.
    # find_by can't even locate the stranded row anymore - encrypt_for_query
    # only has v2 to build candidate ciphertext with, so it builds the WRONG
    # ciphertext for a still-v1 row and the deterministic lookup just misses
    # (an ordinary index miss, not a raised error) - which surfaces to the
    # user as an ordinary "invalid credentials" rejection, not a crash.
    stranded_login_body = URI.encode_www_form('user[email]' => STRANDED_EMAIL, 'user[password]' => PASSWORD, 'authenticity_token' => token)
    stranded_login = http.post('/session', stranded_login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected the stranded (never-migrated) user's login to be rejected as invalid credentials, got #{stranded_login.code}" unless stranded_login.code == '422'
    raise 'expected the stranded login rejection page to actually explain why' unless stranded_login.body.include?('Invalid email or password')

    # Independent proof of exactly WHY it failed: the row on disk never
    # moved off v1 (nobody re-saved it during the transition window), and
    # v2 alone genuinely cannot read it - scanned directly off the store
    # (find_by can't be used here, that's precisely the query path that
    # just failed above for the same reason).
    stranded_row = Prism::Orm.store.all(:users).find { |row| decrypts_under?(V1_SECRET, row['email']) == STRANDED_EMAIL }
    raise 'expected the stranded row to still be findable by scanning raw ciphertext under v1' unless stranded_row
    raise 'expected the stranded row to NOT decrypt under v2 (this is the whole point: it was never re-saved)' if decrypts_under?(V2_SECRET, stranded_row['email'])

    puts 'post_rotation_final: stranded (never-migrated) user correctly locked out after full cutover - ' \
         'confirmed the row is genuinely still v1-only on disk, not a false negative'

    # The login rejection above is a SILENT miss (encrypt_for_query builds
    # the wrong ciphertext candidate and the lookup just finds nothing, an
    # ordinary "invalid credentials" 422). Reading the same row's `.email`
    # directly - by primary key, not through the encrypted-attribute query
    # path - is a genuinely different failure shape: `find` never touches
    # ciphertext (it looks up by plain `id`), so the row loads fine, and it
    # is only the `encrypts :email` reader itself that has no key left to
    # try (current v2 fails, and previous_keys is empty with v1 fully
    # retired) - `decrypt_with_rotation` re-raises the original
    # Encryption::Error instead of returning nil or garbage. Documents the
    # contrast on purpose: a query silently sees nothing, a direct read
    # loudly blows up.
    stranded_user = User.find(stranded_row['id'])
    begin
      stranded_user.email
      raise 'expected reading .email directly on a fully-retired-key row to raise Encryption::Error, it did not raise at all'
    rescue Prism::Orm::Encryption::Error
      puts 'post_rotation_final: direct .email read on the stranded row raised Encryption::Error as expected ' \
           '(no key left that can decrypt it), unlike the silent find_by miss above'
    end
  end
else
  raise "unknown phase #{phase.inspect} (expected signup, rotate_and_login, or post_rotation_final)"
end

server.stop
