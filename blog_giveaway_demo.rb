# Proves Post#with_lock (Prism::Orm::Pessimistic, see ClaimsController#create)
# actually prevents overselling a limited giveaway under real concurrency -
# not threads inside one process, but several genuinely independent
# `Prism::Server` OS processes (see blog_giveaway_worker.rb) all pointed at
# the SAME shared database file, racing to POST /posts/:slug/claims on the
# same post at (as close to) the same instant as a spin-wait barrier on a
# shared "go" file can arrange.
#
# A post with giveaway_slots: 3 and 8 distinct entrants means at most 3 can
# ever legitimately win a slot - if the read-count-then-decide in
# ClaimsController#create were not held under one lock for its entire
# critical section, several of those 8 requests could all read the same
# "2 of 3 claimed" snapshot and all decide a slot was still free, oversold.
require 'fileutils'
require 'rbconfig'
require 'net/http'
require 'tmpdir'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'examples/blog/db/giveaway_demo')
RUBY = RbConfig.ruby
GIVEAWAY_SLOTS = 3
# Capped by examples/blog/app.rb's own 'logins/ip' throttle
# (limit: 5, period: 60) - every entrant below signs in over a real POST
# /session from this same machine's loopback address, exactly like every
# other real visitor would, so this demo has to live within the same
# limit a real attacker would be stopped by rather than special-casing
# itself around it. 5 entrants racing 3 slots is still more than enough
# to prove an oversell is impossible (2 must lose).
ENTRANTS = 5

# Fresh scratch database every run, isolated from examples/blog/db/
# development.pstore (blog_demo.rb's own data).
FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['PRISM_BLOG_DB_DIR'] = SCRATCH_DB_DIR

$LOAD_PATH.unshift(File.join(ROOT, 'lib'))
require 'prism'
require_relative 'examples/blog/app'

def cookie_from(response)
  (response.get_fields('set-cookie') || []).map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

setup_server = Prism::Server.new(Blog, port: 0).start
slug = nil

Net::HTTP.start('127.0.0.1', setup_server.port) do |http|
  # The host: creates the giveaway post. Entrants never author anything,
  # they only ever race to claim a slot on this one post.
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

# ENTRANTS distinct accounts, created directly against the store rather
# than through POST /users - each entrant still authenticates over a real
# POST /session in blog_giveaway_worker.rb (that is the request that has
# to survive examples/blog's real login throttle), but their signups
# happening over HTTP too would trip the SEPARATE 'signups/ip' throttle
# (limit: 3) with only 1 (host) + ENTRANTS of them all coming from this
# same demo process' loopback address - a constraint about this demo
# script issuing many signups back to back, not about the giveaway locking
# this file exists to prove.
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
      { 'PRISM_BLOG_DB_DIR' => SCRATCH_DB_DIR }, RUBY, '-Ilib', 'blog_giveaway_worker.rb',
      label, "#{label}@example.com", 'secret123', slug, go_file,
      chdir: ROOT, out: out_path, err: File.join(scratch, "#{label}.err")
    )
    [pid, out_path]
  end

  # Generous: a cold `ruby` boot of a fresh Prism::Server (migrations
  # re-checked, sign-in, a page load for a CSRF token) per worker, times
  # ENTRANTS of them all starting around the same moment, comfortably
  # finishes well under this - every worker should already be parked on
  # its spin-wait by the time this file appears.
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

# Independent confirmation straight from the store, not just trusting the
# workers' own HTTP responses: a brand new transaction against the same
# file, opened fresh by THIS process, after every worker process has
# already exited and released its own file lock.
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
