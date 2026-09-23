$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require 'fileutils'
require 'rbconfig'

ROOT = __dir__
BLOG_DIR = File.join(ROOT, 'blog')
SCRATCH_DB_DIR = File.join(BLOG_DIR, 'db/seed_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)

def run_facet_cli(*args)
  env = { 'FACET_BLOG_DB_DIR' => SCRATCH_DB_DIR }
  out = IO.popen(env, [RbConfig.ruby, File.join(ROOT, '../bin/facet'), *args],
                 chdir: BLOG_DIR, err: %i[child out], &:read)
  status = $?
  raise "facet #{args.join(' ')} failed (#{status}):\n#{out}" unless status.success?
  out
end

puts '-' * 40
puts 'running: bin/facet db:seed --require=app.rb (real subprocess, real CLI entrypoint, scratch database)'
first_run = run_facet_cli('db:seed', '--require=app.rb')
puts first_run
raise 'expected the first db:seed run to report success' unless first_run.include?('seeded from db/seeds.rb')
unless first_run.include?('users=2 posts=3 comments=2')
  raise 'expected the seeds file to report 2 users/3 posts/2 comments'
end

puts '-' * 40
puts 'running it again to prove examples/blog/db/seeds.rb is idempotent, not just db:seed itself'
second_run = run_facet_cli('db:seed', '--require=app.rb')
puts second_run
unless second_run.include?('users=2 posts=3 comments=2')
  raise 'expected the second db:seed run to leave the same counts behind, not double them'
end

store = Facet::Orm::Store.new(File.join(SCRATCH_DB_DIR, 'development.pstore'))
raise 'expected exactly 2 rows in users after seeding twice' unless store.count('users') == 2
raise 'expected exactly 3 rows in posts after seeding twice' unless store.count('posts') == 3
raise 'expected exactly 2 rows in comments after seeding twice' unless store.count('comments') == 2
puts "  store.count directly off the pstore confirms: users=#{store.count('users')} posts=#{store.count('posts')} comments=#{store.count('comments')}"

puts '-' * 40
puts 'booting examples/blog against the seeded database and fetching GET / over real HTTP'
ENV['FACET_BLOG_DB_DIR'] = SCRATCH_DB_DIR
require_relative 'blog/app'

server = Facet::Server.new(Blog, port: 0).start
port = server.port
begin
  response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
  raise "expected GET / to succeed, got #{response.code}" unless response.code == '200'
  main_list = response.body[/<ul class="posts">.*?<\/ul>/m]
  raise 'expected a <ul class="posts"> listing on the homepage' unless main_list
  ['Welcome to the blog', 'A second seeded post'].each do |title|
    raise "expected the homepage's post list to include the seeded post #{title.inspect}" unless main_list.include?(title)
  end
  if main_list.include?('An unpublished draft')
    raise 'expected the seeded draft post to stay off the published post list'
  end
  puts '  GET / -> 200, both published seeded posts are in the main list, the seeded draft is correctly excluded from it'
ensure
  server.stop
end

puts '-' * 40
puts 'blog_seed_demo done'
