$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require_relative 'blog/app'

label, email, password, slug, go_file = ARGV

def cookie_from(response)
  (response.get_fields('set-cookie') || []).map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

server = Facet::Server.new(Blog, port: 0).start
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

  sleep(0.01) until File.exist?(go_file)

  claim_body = URI.encode_www_form('authenticity_token' => claim_token)
  response = http.post("/posts/#{slug}/claims", claim_body,
                        'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "#{label}: claim request failed (#{response.code})" unless response.code == '302'
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
