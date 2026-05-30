$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require_relative 'examples/blog/app'

server = Prism::Server.new(Blog, port: 0).start
port = server.port
puts "blog demo server on port #{port}"
puts "database file: #{File.join(__dir__, 'examples/blog/db/development.pstore')}"
puts '-' * 40

Net::HTTP.start('127.0.0.1', port) do |http|
  create = http.post(
    '/posts',
    URI.encode_www_form(title: 'Hello from Prism', body: 'This record was written through the ORM-lite file store.'),
    'Content-Type' => 'application/x-www-form-urlencoded'
  )
  puts "POST /posts -> #{create.code} Location=#{create['location']}"

  listing = http.get('/posts')
  puts "GET /posts -> #{listing.code}"
  puts listing.body
end

server.stop
puts '-' * 40
puts 'blog demo done (process about to exit; data stays on disk for the restart check)'
