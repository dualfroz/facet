require 'fileutils'
require 'rbconfig'
require 'net/http'
require 'tmpdir'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'blog/db/giveaway_demo')
RUBY = RbConfig.ruby
GIVEAWAY_SLOTS = 3
ENTRANTS = 5

FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['FACET_BLOG_DB_DIR'] = SCRATCH_DB_DIR

$LOAD_PATH.unshift(File.expand_path('../lib', ROOT))
require 'facet'
require_relative 'blog/app'

def cookie_from(response)
  (response.get_fields('set-cookie') || []).map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

setup_server = Facet::Server.new(Blog, port: 0).start
slug = nil

Net::HTTP.start('127.0.0.1', setup_server.port) do |http|
  new_session = http.get('/session/new')
  cookie = cookie_from(new_session)
  token = csrf_token_from(new_session.body)
  signup_body = URI.encode_www_form(
    'user[email]' => 'host@example.com', 'user[password]' => 'secret123',
    'user[password_confirmation]' => 'secret123', 'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "host signup failed (#{signup.code})" unless signup.code == '302'
  cookie = cookie_from(signup)

  home = http.get('/', 'Cookie' => cookie)
  token = csrf_token_from(home.body)
  create_body = URI.encode_www_form(
    'post[title]' => 'Signed copy giveaway', 'post[body]' => 'Three signed copies, first come first served.',
    'post[giveaway_slots]' => GIVEAWAY_SLOTS.to_s, 'authenticity_token' => token
  )
  created = http.post('/posts', create_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "post creation failed (#{created.code})" unless created.code == '302'
  slug = created['location'][%r{/posts/([^/?]+)}, 1]
  raise 'could not extract slug from Location header' unless slug
end

ENTRANTS.times do |i|
  User.create!(
    'email' => "entrant#{i}@example.com", 'password' => 'secret123', 'password_confirmation' => 'secret123'
  )
end

puts "setup done: post '#{slug}' has #{GIVEAWAY_SLOTS} giveaway slots, #{ENTRANTS} entrants about to race for them"

Dir.mktmpdir('giveaway_demo') do |scratch|
  go_file = File.join(scratch, 'go')
  pids_and_outputs = ENTRANTS.times.map do |i|
    label = "entrant#{i}"
    out_path = File.join(scratch, "#{label}.out")
    pid = Process.spawn(
      { 'FACET_BLOG_DB_DIR' => SCRATCH_DB_DIR }, RUBY, '-I../lib', 'blog_giveaway_worker.rb',
      label, "#{label}@example.com", 'secret123', slug, go_file,
      chdir: ROOT, out: out_path, err: File.join(scratch, "#{label}.err")
    )
    [pid, out_path]
  end

  sleep 3
  File.write(go_file, 'go')

  results = pids_and_outputs.map do |pid, out_path|
    _, status = Process.wait2(pid)
    raise "worker exited with #{status}, see #{out_path}" unless status.success?
    File.read(out_path).strip
  end

  outcomes = results.each_with_object(Hash.new(0)) do |line, tally|
    _label, outcome = line.split(':')
    tally[outcome] += 1
  end

  puts "outcomes across #{ENTRANTS} racing, fully independent server processes: #{outcomes}"
  raise "expected already_claimed count 0, got #{outcomes['already_claimed']}" unless outcomes['already_claimed'].zero?
  raise "expected unknown count 0, got #{outcomes['unknown']}" unless outcomes['unknown'].zero?
  unless outcomes['claimed'] == GIVEAWAY_SLOTS
    raise "expected exactly #{GIVEAWAY_SLOTS} claimed slots, got #{outcomes['claimed']} - Post#with_lock did not " \
          'prevent an oversell'
  end
  unless outcomes['sold_out'] == ENTRANTS - GIVEAWAY_SLOTS
    raise "expected #{ENTRANTS - GIVEAWAY_SLOTS} sold_out responses, got #{outcomes['sold_out']}"
  end
  puts "exactly #{GIVEAWAY_SLOTS} of #{ENTRANTS} racing requests won a slot, the rest correctly saw sold_out - no oversell"
end

post = Post.find(Post.find_by!(slug: slug).id)
claim_count = Claim.where(post_id: post.id).count
if claim_count != GIVEAWAY_SLOTS
  raise "Claim.count on disk is #{claim_count}, expected exactly #{GIVEAWAY_SLOTS}"
end
if post.claims_count != GIVEAWAY_SLOTS
  raise "Post#claims_count is #{post.claims_count}, expected exactly #{GIVEAWAY_SLOTS} (counter cache drifted from the real row count)"
end
puts "storage-level check: Claim.where(post_id: ...).count == #{claim_count}, Post#claims_count == #{post.claims_count}, both exactly #{GIVEAWAY_SLOTS}"
puts 'blog_giveaway_demo done: a hard-capped giveaway held its cap under real cross-process concurrency'
