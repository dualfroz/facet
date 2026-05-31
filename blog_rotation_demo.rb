# Exercises Prism::Orm::Encryption key rotation as a real, multi-process
# lifecycle against examples/blog: provision a user under secret v1 -> boot
# the app with v2 as current and v1 as a previous_keys fallback (the
# "transition period" of a real rotation) -> retire v1 completely and prove
# the migrated row still works. Each phase is a genuinely separate `ruby`
# process (see blog_rotation_worker.rb) because Prism::Orm::Encryption
# derives and memoizes each model's encryption key once per class per
# process - rotating the configured secret only matters if something
# actually re-reads Application#enable_attribute_encryption's config from
# scratch, which means a fresh boot, not an in-process reconfiguration.
require 'fileutils'
require 'rbconfig'

ROOT = __dir__
DB_DIR = File.join(ROOT, 'examples/blog/db/rotation_demo')
RUBY = RbConfig.ruby

# Fresh scratch database every run, isolated from examples/blog/db/
# development.pstore (blog_demo.rb's own data) - re-running this file is
# always deterministic and never fights blog_demo.rb for the same rows.
FileUtils.rm_rf(DB_DIR)

V1_SECRET = 'blog-demo-encryption-secret-v1'.freeze
V2_SECRET = 'blog-demo-encryption-secret-v2'.freeze

def run_phase(phase, env)
  puts '-' * 60
  puts "phase: #{phase}"
  base_env = { 'PRISM_BLOG_DB_DIR' => DB_DIR, 'PRISM_BLOG_ENCRYPTION_PREVIOUS_SECRETS' => '' }
  pid = Process.spawn(base_env.merge(env), RUBY, '-Ilib', 'blog_rotation_worker.rb', phase, chdir: ROOT)
  _, status = Process.wait2(pid)
  raise "phase #{phase} failed with #{status}" unless status.success?
end

run_phase('signup', 'PRISM_BLOG_ENCRYPTION_SECRET' => V1_SECRET)

run_phase('rotate_and_login',
          'PRISM_BLOG_ENCRYPTION_SECRET' => V2_SECRET,
          'PRISM_BLOG_ENCRYPTION_PREVIOUS_SECRETS' => V1_SECRET)

run_phase('post_rotation_final', 'PRISM_BLOG_ENCRYPTION_SECRET' => V2_SECRET)

puts '-' * 60
puts 'blog_rotation_demo done: v1-provisioned user survived rotation to v2 (fallback login while ' \
     'unmigrated, re-save migrated the row, v1 fully retired afterwards); a second, never-migrated ' \
     'user was correctly locked out (not crashed) once v1 was fully retired - all over real HTTP.'
