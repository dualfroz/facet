$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require 'tmpdir'
require 'stringio'

dir = Dir.mktmpdir('facet-strict-n-plus-one-demo')
store = Facet::Orm::Store.new(File.join(dir, 'demo.pstore'))
store.create_table(:authors, %w[id name])
store.create_table(:posts, %w[id title author_id])

class DemoAuthor < Facet::Orm::Model
  table_name :authors
  has_many :posts, class_name: 'DemoPost', foreign_key: 'author_id'
end

class DemoPost < Facet::Orm::Model
  table_name :posts
  belongs_to :author, class_name: 'DemoAuthor', foreign_key: 'author_id'
end

[DemoAuthor, DemoPost].each { |klass| klass.store = store }

3.times do |i|
  author = DemoAuthor.create!(name: "author#{i}")
  DemoPost.create!(title: "post#{i}", author_id: author.id)
end

log = StringIO.new

class DemoApp < Facet::Application
  get('/regression') do
    names = DemoAuthor.all.to_a.map { |author| "#{author.name}: #{author.posts.count} post(s)" }
    names.join(', ')
  end

  get('/clean') do
    names = DemoAuthor.all.includes(:posts).to_a.map { |author| "#{author.name}: #{author.posts.size} post(s)" }
    names.join(', ')
  end
end

def get(port, path)
  Net::HTTP.start('127.0.0.1', port) { |http| http.get(path) }
end

puts '=' * 60
puts 'phase 1: raise_on_violation: true (FACET_BLOG_STRICT_N_PLUS_ONE=1 equivalent)'
Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: log, raise_on_violation: true)
server = Facet::Server.new(DemoApp, port: 0).start
port = server.port

response = get(port, '/regression')
puts "GET /regression -> #{response.code} #{response['Content-Type']} body=#{response.body.inspect}"
raise "expected a real 500, got #{response.code}" unless response.code == '500'
raise 'expected the normal uncaught-exception body, not something ad hoc' unless response.body == 'Internal Server Error'
raise 'expected the violation to still have been logged to the detector io' unless log.string.include?('N+1 query detected: DemoAuthor#posts')
puts 'confirmed: a real 500 response, not a broken connection - the violation was logged, exactly like any other bug'

follow_up = get(port, '/clean')
puts "GET /clean (after the violation) -> #{follow_up.code} body=#{follow_up.body.inspect}"
raise "expected the clean route to still work fine after a violation elsewhere, got #{follow_up.code}" unless follow_up.code == '200'
raise 'expected includes(:posts) to prevent any lazy load / violation' if log.string.scan('N+1 query detected').size > 1
puts 'confirmed: eager-loaded route stays silent and the server keeps serving requests after a violation'

Facet::Orm::NPlusOneDetector.disable!
Facet::Orm::NPlusOneDetector.reset!

puts '-' * 60
puts 'phase 2: log-only mode (raise_on_violation: false, the default when FACET_BLOG_STRICT_N_PLUS_ONE is unset)'
log2 = StringIO.new
Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: log2, raise_on_violation: false)

response2 = get(port, '/regression')
puts "GET /regression -> #{response2.code} body=#{response2.body.inspect}"
raise "expected a normal 200 in log-only mode, got #{response2.code}" unless response2.code == '200'
raise 'expected the SAME regression to still be logged, just not raised' unless log2.string.include?('N+1 query detected: DemoAuthor#posts')
puts 'confirmed: same regression, same log line, but the response is a plain 200 - nothing breaks for real traffic ' \
     'when the strict flag is off'

Facet::Orm::NPlusOneDetector.disable!
Facet::Orm::NPlusOneDetector.reset!

puts '=' * 60
puts 'strict_n_plus_one_demo done: raise_on_violation now surfaces as a normal 500 over real HTTP (never a dead ' \
     'connection), and the same underlying regression is silent-but-logged when the strict flag is off.'
