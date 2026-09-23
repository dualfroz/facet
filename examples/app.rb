$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'

class ExampleApp < Facet::Application
  enable_sessions(secret: 'facet-demo-secret')
  use Facet::Middleware::Logger

  helpers do
    def layout(title, inner)
      erb(<<~TEMPLATE, locals: { title: title, inner: inner })
        <!doctype html>
        <html><head><title><%= title %></title></head>
        <body><%== inner %></body></html>
      TEMPLATE
    end
  end

  get '/' do
    html('<h1>Facet</h1>')
  end

  get '/hello/:name' do
    greeting = erb('<p>Hello, <%= name %>!</p>', locals: { name: params['name'] })
    layout('Hello', greeting)
  end

  get '/search' do
    json(query: params['q'], page: params['page'])
  end

  post '/echo' do
    json(received: params.to_h)
  end

  get '/files/*' do
    json(path: params['splat'])
  end

  group '/api' do
    get '/status' do
      json(ok: true)
    end
  end

  get '/count' do
    session['count'] = (session['count'] || 0) + 1
    json(count: session['count'])
  end

  get '/old' do
    redirect '/', 301
  end
end

if __FILE__ == $PROGRAM_NAME
  server = Facet::Server.new(ExampleApp, port: (ARGV[0] || 0).to_i).start
  puts "Facet example listening on #{server.url}"
  trap('INT') do
    server.stop
    exit
  end
  sleep
end
