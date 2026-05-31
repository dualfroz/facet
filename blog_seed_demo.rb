# End-to-end proof of `prism db:seed` (Prism::Cli#db_seed, lib/prism/cli.rb)
# against examples/blog: runs the real bin/prism executable as its own OS
# process (the actual CLI entrypoint a developer or a deploy script would
# invoke, not just the Ruby API) against a scratch database, twice in a row
# to prove examples/blog/db/seeds.rb is idempotent (find_by-before-create,
# not create!-every-time), then boots the seeded database through the real
# app and a real HTTP GET / to prove the seeded posts are what a visitor
# actually sees - not just rows sitting in a pstore nobody rendered.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'fileutils'
require 'rbconfig'

ROOT = __dir__
BLOG_DIR = File.join(ROOT, 'examples/blog')
SCRATCH_DB_DIR = File.join(BLOG_DIR, 'db/seed_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)

def run_prism_cli(*args)
  env = { 'PRISM_BLOG_DB_DIR' => SCRATCH_DB_DIR }
  out = IO.popen(env, [RbConfig.ruby, File.join(ROOT, 'bin/prism'), *args],
                 chdir: BLOG_DIR, err: %i[child out], &:read)
  status = $?
  raise "prism #{args.join(' ')} failed (#{status}):\n#{out}" unless status.success?
  out
end

puts '-' * 40
puts 'running: bin/prism db:seed --require=app.rb (real subprocess, real CLI entrypoint, scratch database)'
first_run = run_prism_cli('db:seed', '--require=app.rb')
puts first_run
raise 'expected the first db:seed run to report success' unless first_run.include?('seeded from db/seeds.rb')
unless first_run.include?('users=2 posts=3 comments=2')
  raise 'expected the seeds file to report 2 users/3 posts/2 comments'
end

puts '-' * 40
puts 'running it again to prove examples/blog/db/seeds.rb is idempotent, not just db:seed itself'
second_run = run_prism_cli('db:seed', '--require=app.rb')
puts second_run
unless second_run.include?('users=2 posts=3 comments=2')
  raise 'expected the second db:seed run to leave the same counts behind, not double them'
end

store = Prism::Orm::Store.new(File.join(SCRATCH_DB_DIR, 'development.pstore'))
raise 'expected exactly 2 rows in users after seeding twice' unless store.count('users') == 2
raise 'expected exactly 3 rows in posts after seeding twice' unless store.count('posts') == 3
raise 'expected exactly 2 rows in comments after seeding twice' unless store.count('comments') == 2
puts "  store.count directly off the pstore confirms: users=#{store.count('users')} posts=#{store.count('posts')} comments=#{store.count('comments')}"

puts '-' * 40
puts 'booting examples/blog against the seeded database and fetching GET / over real HTTP'
ENV['PRISM_BLOG_DB_DIR'] = SCRATCH_DB_DIR
require_relative 'examples/blog/app'

server = Prism::Server.new(Blog, port: 0).start
port = server.port
begin
  response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
  raise "expected GET / to succeed, got #{response.code}" unless response.code == '200'
  # The main <ul class="posts"> listing is PostsController#index's own
  # Post.published scope - the sidebar's "recent posts" widget just above it
  # is a separate, deliberately unscoped Post.order(...).limit(5) (see
  # examples/blog/app/views/posts/index.erb) that shows every post
  # regardless of status, drafts included, so only the main list is the
  # right place to check that a draft stays unpublished.
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
