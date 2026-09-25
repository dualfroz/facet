require 'minitest/autorun'
require 'facet'
require 'support'

class ResourceApp < Facet::Application
  enable_sessions(secret: 'routing-secret')

  root(to: 'welcome#show')

  resources :routing_posts, only: %i[index show create]
  resources :routing_comments, only: %i[destroy]

  get '/whoami' do
    json(path: url_for(:routing_post, id: 5))
  end

  get '/destroy-link' do
    json(path: url_for(:routing_comment, id: 7))
  end

  get '/write-flash' do
    flash[:notice] = 'saved!'
    redirect '/after-flash'
  end

  get '/after-flash' do
    json(notice: flash[:notice])
  end
end

class WelcomeController < Facet::Controller
  def show
    html('welcome')
  end
end

class RoutingPostsController < Facet::Controller
  def index
    json(action: 'index')
  end

  def show
    json(action: 'show', id: params['id'])
  end

  def create
    json(action: 'create')
  end
end

class RoutingCommentsController < Facet::Controller
  def destroy
    json(action: 'destroy', id: params['id'])
  end
end

class ApplicationRoutingTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    ResourceApp.call(env_for(method, path, **opts))
  end

  def test_root_dispatches_to_controller
    status, _, body = call('GET', '/')
    assert_equal 200, status
    assert_equal 'welcome', body.join
  end

  def test_resources_index
    _, _, body = call('GET', '/routing_posts')
    assert_equal({ 'action' => 'index' }, JSON.parse(body.join))
  end

  def test_resources_show
    _, _, body = call('GET', '/routing_posts/9')
    assert_equal({ 'action' => 'show', 'id' => '9' }, JSON.parse(body.join))
  end

  def test_resources_create
    _, _, body = call('POST', '/routing_posts')
    assert_equal({ 'action' => 'create' }, JSON.parse(body.join))
  end

  def test_resources_only_registers_requested_actions
    status, = call('DELETE', '/routing_posts/1')
    assert_equal 404, status
  end

  def test_url_for_named_resource_route
    _, _, body = call('GET', '/whoami')
    assert_equal '/routing_posts/5', JSON.parse(body.join)['path']
  end

  def test_resources_destroy_dispatches
    _, _, body = call('DELETE', '/routing_comments/3')
    assert_equal({ 'action' => 'destroy', 'id' => '3' }, JSON.parse(body.join))
  end

  def test_url_for_named_resource_route_for_destroy_only_resource
    _, _, body = call('GET', '/destroy-link')
    assert_equal '/routing_comments/7', JSON.parse(body.join)['path']
  end

  def test_flash_survives_a_redirect
    status, headers, = call('GET', '/write-flash')
    assert_equal 302, status
    cookie = headers['Set-Cookie'].split(';').first
    _, _, body = call('GET', '/after-flash', cookies: cookie)
    assert_equal 'saved!', JSON.parse(body.join)['notice']
  end

  def test_flash_does_not_survive_a_second_request
    _, headers, = call('GET', '/write-flash')
    cookie = headers['Set-Cookie'].split(';').first
    _, headers2, = call('GET', '/after-flash', cookies: cookie)
    cookie2 = headers2['Set-Cookie']&.split(';')&.first || cookie
    _, _, body = call('GET', '/after-flash', cookies: cookie2)
    assert_nil JSON.parse(body.join)['notice']
  end

  def test_controller_dispatch_enriches_process_action_payload
    events = []
    subscriber = Facet::Instrumentation.subscribe('process_action.facet') { |event| events << event }
    begin
      call('GET', '/routing_posts/9')
    ensure
      Facet::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal 1, events.size
    assert_equal 'routing_posts', events.first.payload[:controller]
    assert_equal 'show', events.first.payload[:action]
    assert_equal 200, events.first.payload[:status]
  end
end
