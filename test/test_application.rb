require 'minitest/autorun'
require 'prism'
require 'support'

class SampleApp < Prism::Application
  enable_sessions(secret: 'test-secret')

  before '/admin/*' do
    halt(401, 'unauthorized') unless params['token'] == 'let-me-in'
  end

  get '/' do
    'root'
  end

  get '/users/:id' do
    json(id: params['id'])
  end

  get '/search' do
    json(q: params['q'])
  end

  post '/echo' do
    json(got: params.to_h)
  end

  get '/old' do
    redirect '/new', 301
  end

  get '/greet/:name' do
    erb('<h1>Hi <%= name %></h1>', locals: { name: params['name'] })
  end

  get '/admin/panel' do
    json(secret: 'shown')
  end

  get '/count' do
    session['count'] = (session['count'] || 0) + 1
    json(count: session['count'])
  end

  get '/first' do
    pass if params['skip'] == 'yes'
    'first'
  end

  get '/first' do
    'second'
  end
end

class ApplicationTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    SampleApp.call(env_for(method, path, **opts))
  end

  def test_root
    status, _, body = call('GET', '/')
    assert_equal 200, status
    assert_equal 'root', body.join
  end

  def test_path_param
    status, headers, body = call('GET', '/users/77')
    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal({ 'id' => '77' }, JSON.parse(body.join))
  end

  def test_query_param
    _, _, body = call('GET', '/search?q=prism')
    assert_equal({ 'q' => 'prism' }, JSON.parse(body.join))
  end

  def test_post_json
    payload = JSON.generate(name: 'x', n: 5)
    _, _, body = call('POST', '/echo', headers: { 'Content-Type' => 'application/json' }, body: payload)
    assert_equal({ 'name' => 'x', 'n' => 5 }, JSON.parse(body.join)['got'])
  end

  def test_redirect
    status, headers, = call('GET', '/old')
    assert_equal 301, status
    assert_equal '/new', headers['Location']
  end

  def test_not_found
    status, _, body = call('GET', '/missing')
    assert_equal 404, status
    assert_includes body.join, 'Not Found'
  end

  def test_template_escaping
    _, _, body = call('GET', '/greet/%3Cb%3E')
    assert_equal '<h1>Hi &lt;b&gt;</h1>', body.join
  end

  def test_before_filter_blocks
    status, _, body = call('GET', '/admin/panel')
    assert_equal 401, status
    assert_equal 'unauthorized', body.join
  end

  def test_before_filter_allows
    status, _, body = call('GET', '/admin/panel?token=let-me-in')
    assert_equal 200, status
    assert_equal 'shown', JSON.parse(body.join)['secret']
  end

  def test_session_write_and_read
    _, headers, body = call('GET', '/count')
    assert_equal 1, JSON.parse(body.join)['count']
    cookie = headers['Set-Cookie'].split(';').first
    name, value = cookie.split('=', 2)
    _, _, body2 = call('GET', '/count', cookies: "#{name}=#{value}")
    assert_equal 2, JSON.parse(body2.join)['count']
  end

  def test_pass
    _, _, body = call('GET', '/first?skip=yes')
    assert_equal 'second', body.join
    _, _, second = call('GET', '/first')
    assert_equal 'first', second.join
  end

  def test_head_has_empty_body
    status, _, body = call('HEAD', '/')
    assert_equal 200, status
    assert_equal '', body.join
  end

  def test_dispatch_emits_process_action_event_with_status
    events = []
    subscriber = Prism::Instrumentation.subscribe('process_action.prism') { |event| events << event }
    begin
      call('GET', '/users/9')
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal 1, events.size
    assert_equal 'GET', events.first.payload[:method]
    assert_equal '/users/9', events.first.payload[:path]
    assert_equal 200, events.first.payload[:status]
  end

  def test_dispatch_emits_event_for_not_found_too
    events = []
    subscriber = Prism::Instrumentation.subscribe('process_action.prism') { |event| events << event }
    begin
      call('GET', '/missing')
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal 1, events.size
    assert_equal 404, events.first.payload[:status]
  end
end
