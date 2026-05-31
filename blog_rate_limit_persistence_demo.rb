# Exercises Prism::RateLimiter::PStoreStore (wired into examples/blog in
# this session, see app.rb) as a real, multi-process lifecycle: trip the
# logins/ip throttle from one OS process, kill it, then boot a completely
# independent second process and prove its very first request already
# comes back throttled - the durability MemoryStore could never give,
# proven the same way blog_rotation_demo.rb proves key rotation: each
# phase is a genuinely separate `ruby` invocation (see
# blog_rate_limit_worker.rb), not just a different in-process call.
#
# Repeats the same lifecycle for signups/ip, the OTHER throttle rule
# sharing this PStoreStore file - a prior session proved only logins/ip
# survives a restart; nothing had shown the two rules do not somehow
# clobber each other's window in the same file (they are keyed by rule
# name, not just by IP, but that was only true by reading the code).
require 'fileutils'
require 'rbconfig'

ROOT = __dir__
DB_DIR = File.join(ROOT, 'examples/blog/db/rate_limit_demo')
RUBY = RbConfig.ruby

# Fresh scratch database every run, isolated from examples/blog/db/
# development.pstore (blog_demo.rb's own data) - re-running this file is
# always deterministic and never fights blog_demo.rb for the same throttle
# window.
FileUtils.rm_rf(DB_DIR)

def run_phase(phase)
  puts '-' * 60
  puts "phase: #{phase}"
  pid = Process.spawn({ 'PRISM_BLOG_DB_DIR' => DB_DIR }, RUBY, '-Ilib', 'blog_rate_limit_worker.rb', phase, chdir: ROOT)
  _, status = Process.wait2(pid)
  raise "phase #{phase} failed with #{status}" unless status.success?
end

run_phase('trip')
run_phase('confirm_still_blocked')
run_phase('trip_signup')
run_phase('confirm_signup_still_blocked')

puts '-' * 60
puts 'blog_rate_limit_persistence_demo done: both the login throttle and the independent signup throttle ' \
     'tripped by one process were still enforced by a completely independent later process against the ' \
     'same PStoreStore file - a plain process restart (deploy, crash, worker respawn) does not hand an ' \
     'attacker a fresh throttle window for either rule, and the two rules did not clobber each other.'
