$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require_relative 'examples/app'

server = Prism::Server.new(ExampleApp, port: 0).start
port = server.port
puts "demo server on port #{port}"
puts '-' * 40

Net::HTTP.start('127.0.0.1', port) do |http|
  hello = http.get('/hello/Ruby')
  puts "GET /hello/Ruby -> #{hello.code}"
  puts hello.body

  search = http.get('/search?q=prism&page=2')
  puts "GET /search?q=prism&page=2 -> #{search.code} #{search.body}"

  echo = http.post('/echo', JSON.generate(name: 'foksiu', role: 'admin'), 'Content-Type' => 'application/json')
  puts "POST /echo -> #{echo.code} #{echo.body}"

  files = http.get('/files/docs/readme.txt')
  puts "GET /files/docs/readme.txt -> #{files.code} #{files.body}"

  status = http.get('/api/status')
  puts "GET /api/status -> #{status.code} #{status.body}"

  first = http.get('/count')
  cookie = first['set-cookie'].split(';').first
  puts "GET /count -> #{first.body} (cookie issued: #{!first['set-cookie'].nil?})"
  second = http.get('/count', 'Cookie' => cookie)
  puts "GET /count (with cookie) -> #{second.body}"

  redirect = http.get('/old')
  puts "GET /old -> #{redirect.code} Location=#{redirect['location']}"
end

server.stop
puts '-' * 40
puts 'demo done'
