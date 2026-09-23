require 'fileutils'
require 'rbconfig'

ROOT = __dir__
DB_DIR = File.join(ROOT, 'blog/db/session_rotation_demo')
RUBY = RbConfig.ruby

FileUtils.rm_rf(DB_DIR)
FileUtils.mkdir_p(DB_DIR)

V1_SECRET = 'blog-demo-session-secret-v1'.freeze
V2_SECRET = 'blog-demo-session-secret-v2'.freeze

def run_phase(phase, env)
  puts '-' * 60
  puts "phase: #{phase}"
  base_env = { 'FACET_BLOG_DB_DIR' => DB_DIR, 'FACET_BLOG_SESSION_PREVIOUS_SECRETS' => '' }
  pid = Process.spawn(base_env.merge(env), RUBY, '-I../lib', 'blog_session_secret_rotation_worker.rb', phase, chdir: ROOT)
  _, status = Process.wait2(pid)
  raise "phase #{phase} failed with #{status}" unless status.success?
end

run_phase('signup', 'FACET_BLOG_SESSION_SECRET' => V1_SECRET)

run_phase('rotate',
          'FACET_BLOG_SESSION_SECRET' => V2_SECRET,
          'FACET_BLOG_SESSION_PREVIOUS_SECRETS' => V1_SECRET)

run_phase('post_rotation_final', 'FACET_BLOG_SESSION_SECRET' => V2_SECRET)

puts '-' * 60
puts 'blog_session_secret_rotation_demo done: a session written to during the rotation window (user A, via a ' \
     'real post creation) was transparently re-signed onto the new secret and survived full cutover; a session ' \
     'never written to again after signing in under the retired secret (user B) was correctly logged out, not ' \
     'crashed, once that secret was fully retired - all over real HTTP across independent processes.'
