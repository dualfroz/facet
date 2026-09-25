require 'minitest/autorun'
require 'facet'
require 'net/http'

class IntegrationApp < Facet::Application
  get '/ping' do
    json(pong: true)
  end

  get '/hello/:name' do
    json(hello: params['name'])
  end

  post '/sum' do
    numbers = JSON.parse(request.body)
    json(sum: numbers['a'] + numbers['b'])
  end
end

class IntegrationTest < Minitest::Test
  def setup
    @server = Facet::Server.new(IntegrationApp, port: 0).start
    @port = @server.port
  end

  def teardown
    @server.stop
  end

  def test_port_is_ephemeral
    assert @port.positive?
  end

  def test_get_with_param
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/hello/Ruby"))
    assert_equal '200', response.code
    assert_equal({ 'hello' => 'Ruby' }, JSON.parse(response.body))
  end

  def test_post_with_body
    uri = URI("http://127.0.0.1:#{@port}/sum")
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      http.post(uri.path, JSON.generate(a: 2, b: 40), 'Content-Type' => 'application/json')
    end
    assert_equal '200', response.code
    assert_equal 42, JSON.parse(response.body)['sum']
  end

  def test_not_found_over_http
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/nope"))
    assert_equal '404', response.code
  end
end
