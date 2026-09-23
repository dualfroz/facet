require 'fileutils'
require 'rbconfig'

ROOT = __dir__
DB_DIR = File.join(ROOT, 'blog/db/rate_limit_demo')
RUBY = RbConfig.ruby

FileUtils.rm_rf(DB_DIR)

def run_phase(phase)
  puts '-' * 60
  puts "phase: #{phase}"
  pid = Process.spawn({ 'FACET_BLOG_DB_DIR' => DB_DIR }, RUBY, '-I../lib', 'blog_rate_limit_worker.rb', phase, chdir: ROOT)
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
