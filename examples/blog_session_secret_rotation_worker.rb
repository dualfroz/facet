$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require 'fileutils'
require_relative 'blog/app'

COOKIE_A_V1_PATH = File.join(DB_DIR, 'cookie_a_v1.txt')
COOKIE_B_V1_PATH = File.join(DB_DIR, 'cookie_b_v1.txt')
COOKIE_A_V2_PATH = File.join(DB_DIR, 'cookie_a_v2.txt')

EMAIL_A = 'rotation-a@example.com'.freeze
EMAIL_B = 'rotation-b@example.com'.freeze
PASSWORD = 'correct horse battery staple v2'.freeze

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

def sign_up(http, email)
  home = http.get('/')
  cookie = cookie_from(home)
  token = csrf_token_from(home.body)
  body = URI.encode_www_form(
    'user[email]' => email, 'user[password]' => PASSWORD, 'user[password_confirmation]' => PASSWORD,
    'authenticity_token' => token
  )
  response = http.post('/users', body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected sign-up for #{email} to redirect, got #{response.code}" unless response.code == '302'
  cookie_from(response)
end

phase = ARGV[0]

server = Facet::Server.new(Blog, port: 0).start
port = server.port

case phase
when 'signup'
  Net::HTTP.start('127.0.0.1', port) do |http|
    File.write(COOKIE_A_V1_PATH, sign_up(http, EMAIL_A))
    puts 'signup: user A signed up and signed in under v1 - will write to their session during the rotation window'

    File.write(COOKIE_B_V1_PATH, sign_up(http, EMAIL_B))
    puts 'signup: user B signed up and signed in under v1 too - deliberately left untouched from here on, stranded on v1'
  end
when 'rotate'
  Net::HTTP.start('127.0.0.1', port) do |http|
    cookie_a = File.read(COOKIE_A_V1_PATH).strip
    cookie_b = File.read(COOKIE_B_V1_PATH).strip

    edit_a = http.get('/account/edit', 'Cookie' => cookie_a)
    raise "expected user A's v1-signed session to still authenticate via previous_secrets, got #{edit_a.code}" unless edit_a.code == '200'

    edit_b = http.get('/account/edit', 'Cookie' => cookie_b)
    raise "expected user B's v1-signed session to still authenticate via previous_secrets, got #{edit_b.code}" unless edit_b.code == '200'
    puts 'rotate: both v1-signed sessions still authenticate under v2-current/v1-previous'

    edit_token = csrf_token_from(edit_a.body)
    create_body = URI.encode_www_form(
      'post[title]' => 'Written during the secret rotation window',
      'post[body]' => 'This post exists to force a session write while v2 is current.',
      'authenticity_token' => edit_token
    )
    created = http.post('/posts', create_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie_a)
    raise "expected creating a post to redirect, got #{created.code}" unless created.code == '302'

    cookie_a_v2 = cookie_from(created)
    raise 'expected the flash-notice write to actually re-sign the session cookie' if cookie_a_v2.empty?
    raise 'expected the re-signed cookie to differ from the original v1-signed one' if cookie_a_v2 == cookie_a
    File.write(COOKIE_A_V2_PATH, cookie_a_v2)
    puts 'rotate: user A wrote to their session (created a post) and got re-signed onto v2 in the same response'

    puts 'rotate: user B deliberately left untouched (still v1-signed on the wire)'
  end
when 'post_rotation_final'
  Net::HTTP.start('127.0.0.1', port) do |http|
    cookie_a_v2 = File.read(COOKIE_A_V2_PATH).strip
    cookie_b_v1 = File.read(COOKIE_B_V1_PATH).strip

    edit_a = http.get('/account/edit', 'Cookie' => cookie_a_v2)
    raise "expected user A's rotated (v2-signed) session to survive full cutover, got #{edit_a.code}" unless edit_a.code == '200'
    puts 'post_rotation_final: user A (session written during the transition window) still authenticated with v1 fully retired'

    edit_b = http.get('/account/edit', 'Cookie' => cookie_b_v1)
    raise "expected user B's never-rewritten v1-only session to be logged out after full cutover, got #{edit_b.code}" unless edit_b.code == '302'
    raise 'expected the logged-out redirect to point at the login page' unless edit_b['Location'].to_s.end_with?('/session/new')
    puts 'post_rotation_final: user B (never wrote to their session again) correctly logged out after v1 was fully retired'
  end
else
  raise "unknown phase #{phase.inspect} (expected signup, rotate, or post_rotation_final)"
end

server.stop
