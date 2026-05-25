$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(__dir__)

require 'minitest/autorun'

Dir[File.join(__dir__, 'test_*.rb')].sort.each { |file| require file }
