require 'fileutils'
require 'rbconfig'

ROOT = __dir__
DB_DIR = File.join(ROOT, 'blog/db/rotation_demo')
RUBY = RbConfig.ruby

FileUtils.rm_rf(DB_DIR)

V1_SECRET = 'blog-demo-encryption-secret-v1'.freeze
V2_SECRET = 'blog-demo-encryption-secret-v2'.freeze

def run_phase(phase, env)
  puts '-' * 60
  puts "phase: #{phase}"
  base_env = { 'FACET_BLOG_DB_DIR' => DB_DIR, 'FACET_BLOG_ENCRYPTION_PREVIOUS_SECRETS' => '' }
  pid = Process.spawn(base_env.merge(env), RUBY, '-I../lib', 'blog_rotation_worker.rb', phase, chdir: ROOT)
  _, status = Process.wait2(pid)
  raise "phase #{phase} failed with #{status}" unless status.success?
end

run_phase('signup', 'FACET_BLOG_ENCRYPTION_SECRET' => V1_SECRET)

run_phase('rotate_and_login',
          'FACET_BLOG_ENCRYPTION_SECRET' => V2_SECRET,
          'FACET_BLOG_ENCRYPTION_PREVIOUS_SECRETS' => V1_SECRET)

run_phase('post_rotation_final', 'FACET_BLOG_ENCRYPTION_SECRET' => V2_SECRET)

puts '-' * 60
puts 'blog_rotation_demo done: v1-provisioned user survived rotation to v2 (fallback login while ' \
     'unmigrated, re-save migrated the row, v1 fully retired afterwards); a second, never-migrated ' \
     'user was correctly locked out (not crashed) once v1 was fully retired - all over real HTTP.'
