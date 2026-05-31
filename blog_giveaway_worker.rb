# One entrant's attempt to claim a limited giveaway slot, run as its own,
# completely independent `ruby` process - a real second (third, fourth...)
# `Prism::Server` instance booted against the SAME shared database file as
# every other worker (see blog_giveaway_demo.rb, which spawns several of
# these at once and only then releases them all together), not just
# another thread inside one process. This is the scenario
# ClaimsController#create's `post.with_lock` (Prism::Orm::Pessimistic) has
# to hold up against for real: several independent app-server processes -
# think several Puma/Unicorn workers behind a load balancer, all pointed
# at the same database - racing the same "claim now" button on the same
# post at (as close to) the same instant as this demo can arrange.
#
# ARGV: label email password slug go_file
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require_relative 'examples/blog/app'

label, email, password, slug, go_file = ARGV

def cookie_from(response)
  (response.get_fields('set-cookie') || []).map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

server = Prism::Server.new(Blog, port: 0).start
port = server.port

Net::HTTP.start('127.0.0.1', port) do |http|
  sign_in_page = http.get('/session/new')
  cookie = cookie_from(sign_in_page)
  token = csrf_token_from(sign_in_page.body)
  login_body = URI.encode_www_form('user[email]' => email, 'user[password]' => password, 'authenticity_token' => token)
  signed_in = http.post('/session', login_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "#{label}: sign-in failed (#{signed_in.code})" unless signed_in.code == '302'
  new_cookie = cookie_from(signed_in)
  cookie = new_cookie unless new_cookie.empty?

  show_page = http.get("/posts/#{slug}", 'Cookie' => cookie)
  raise "#{label}: could not load post page (#{show_page.code})" unless show_page.code == '200'
  claim_token = csrf_token_from(show_page.body)

  # Every worker reaches this point at its own pace (fresh Ruby boot, fresh
  # Prism::Server, its own sign-in round trip) - spin-waiting on a file the
  # demo only creates once ALL workers have been spawned turns "started at
  # roughly the same time" into "fires the actual claim request at
  # (approximately) the same instant", which is the moment that actually
  # needs to race for this demo to mean anything.
  sleep(0.01) until File.exist?(go_file)

  claim_body = URI.encode_www_form('authenticity_token' => claim_token)
  response = http.post("/posts/#{slug}/claims", claim_body,
                        'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "#{label}: claim request failed (#{response.code})" unless response.code == '302'
  # The flash notice this redirect just set lives in the session cookie
  # itself (see Prism::Session) - the Set-Cookie on THIS response, not the
  # one from the earlier sign-in, is what carries it forward.
  post_claim_cookie = cookie_from(response)
  cookie = post_claim_cookie unless post_claim_cookie.empty?

  landed = http.get(response['location'], 'Cookie' => cookie)
  outcome =
    if landed.body.include?('You claimed a giveaway slot!')
      'claimed'
    elsif landed.body.include?('Sorry, this giveaway is sold out')
      'sold_out'
    elsif landed.body.include?('You already claimed a slot for this giveaway')
      'already_claimed'
    else
      'unknown'
    end
  puts "#{label}:#{outcome}"
end
