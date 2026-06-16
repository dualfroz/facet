# Proves, over a real TCP socket (not just a direct Application.call like
# test/test_application_n_plus_one.rb), what examples/blog/app.rb's
# PRISM_BLOG_STRICT_N_PLUS_ONE=1 gate actually buys: before this session,
# Orm::NPlusOneDetector.report! was called AFTER Application#dispatch's
# instrumented span had already closed its rescue reach, so a violation blew
# straight out of #dispatch, past every middleware, and past
# Server#serve's `@app.call(env)` too (server.rb only rescues
# Errno::EPIPE/Errno::ECONNRESET/IOError around that call, never plain
# StandardError) - the request thread died with the socket just closed and
# NOT ONE byte written back, i.e. a client seeing a broken connection, not an
# HTTP response. #dispatch now rescues the violation in the same place as
# any other bug and routes it through handle_uncaught_exception, so
# raise_on_violation actually behaves like every other exception in this
# framework: a normal 500 a curl/CI run can see and assert on.
#
# Uses a tiny synthetic app (not examples/blog, which is deliberately kept
# N+1-free) with ONE route that has a real, deliberately-unfixed N+1 -
# reintroducing a genuine bug is exactly what a regression gate needs to be
# proven against; asserting against blog's own already-clean routes would
# only prove "doesn't false-positive," not "catches a real regression."
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'tmpdir'
require 'stringio'

dir = Dir.mktmpdir('prism-strict-n-plus-one-demo')
store = Prism::Orm::Store.new(File.join(dir, 'demo.pstore'))
store.create_table(:authors, %w[id name])
store.create_table(:posts, %w[id title author_id])

class DemoAuthor < Prism::Orm::Model
  table_name :authors
  has_many :posts, class_name: 'DemoPost', foreign_key: 'author_id'
end

class DemoPost < Prism::Orm::Model
  table_name :posts
  belongs_to :author, class_name: 'DemoAuthor', foreign_key: 'author_id'
end

[DemoAuthor, DemoPost].each { |klass| klass.store = store }

3.times do |i|
  author = DemoAuthor.create!(name: "author#{i}")
  DemoPost.create!(title: "post#{i}", author_id: author.id)
end

log = StringIO.new

class DemoApp < Prism::Application
  # Genuinely N+1: no .includes(:posts), so each author's #posts is a lazy
  # cache-miss load - exactly the pattern examples/blog's PostsController
  # used to have on Comment#likes before it was found and fixed (see
  # docs/plan/prism/stan.md, N+1 detector session).
  get('/regression') do
    names = DemoAuthor.all.to_a.map { |author| "#{author.name}: #{author.posts.count} post(s)" }
    names.join(', ')
  end

  # Same query, fixed the way PostsController actually was: eager-loaded, so
  # no lazy load ever fires and the detector has nothing to count.
  get('/clean') do
    names = DemoAuthor.all.includes(:posts).to_a.map { |author| "#{author.name}: #{author.posts.size} post(s)" }
    names.join(', ')
  end
end

def get(port, path)
  Net::HTTP.start('127.0.0.1', port) { |http| http.get(path) }
end

puts '=' * 60
puts 'phase 1: raise_on_violation: true (PRISM_BLOG_STRICT_N_PLUS_ONE=1 equivalent)'
Prism::Orm::NPlusOneDetector.enable!(threshold: 2, io: log, raise_on_violation: true)
server = Prism::Server.new(DemoApp, port: 0).start
port = server.port

response = get(port, '/regression')
puts "GET /regression -> #{response.code} #{response['Content-Type']} body=#{response.body.inspect}"
raise "expected a real 500, got #{response.code}" unless response.code == '500'
raise 'expected the normal uncaught-exception body, not something ad hoc' unless response.body == 'Internal Server Error'
raise 'expected the violation to still have been logged to the detector io' unless log.string.include?('N+1 query detected: DemoAuthor#posts')
puts 'confirmed: a real 500 response, not a broken connection - the violation was logged, exactly like any other bug'

# The connection dying silently (the pre-fix behavior) would have made this
# second request on a FRESH connection unremarkable either way - the real
# proof is that the server thread handling /regression is still alive and
# the process itself never crashed, which this second, unrelated request
# after the violation demonstrates.
follow_up = get(port, '/clean')
puts "GET /clean (after the violation) -> #{follow_up.code} body=#{follow_up.body.inspect}"
raise "expected the clean route to still work fine after a violation elsewhere, got #{follow_up.code}" unless follow_up.code == '200'
raise 'expected includes(:posts) to prevent any lazy load / violation' if log.string.scan('N+1 query detected').size > 1
puts 'confirmed: eager-loaded route stays silent and the server keeps serving requests after a violation'

Prism::Orm::NPlusOneDetector.disable!
Prism::Orm::NPlusOneDetector.reset!

puts '-' * 60
puts 'phase 2: log-only mode (raise_on_violation: false, the default when PRISM_BLOG_STRICT_N_PLUS_ONE is unset)'
log2 = StringIO.new
Prism::Orm::NPlusOneDetector.enable!(threshold: 2, io: log2, raise_on_violation: false)

response2 = get(port, '/regression')
puts "GET /regression -> #{response2.code} body=#{response2.body.inspect}"
raise "expected a normal 200 in log-only mode, got #{response2.code}" unless response2.code == '200'
raise 'expected the SAME regression to still be logged, just not raised' unless log2.string.include?('N+1 query detected: DemoAuthor#posts')
puts 'confirmed: same regression, same log line, but the response is a plain 200 - nothing breaks for real traffic ' \
     'when the strict flag is off'

Prism::Orm::NPlusOneDetector.disable!
Prism::Orm::NPlusOneDetector.reset!

puts '=' * 60
puts 'strict_n_plus_one_demo done: raise_on_violation now surfaces as a normal 500 over real HTTP (never a dead ' \
     'connection), and the same underlying regression is silent-but-logged when the strict flag is off.'
