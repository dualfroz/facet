require 'minitest/autorun'
require 'facet'

class IntegrationSampleApp < Facet::Application
  enable_sessions(secret: 'integration-test-secret')

  get '/' do
    'welcome'
  end

  get '/dashboard' do
    halt(401, 'not logged in') unless session['user']
    "hello #{session['user']}"
  end

  post '/login' do
    name = params['user'] && params['user']['name']
    if name == 'alice'
      session['user'] = name
      redirect '/dashboard'
    else
      halt(401, 'bad credentials')
    end
  end

  post '/logout' do
    session.clear
    redirect '/'
  end

  get '/echo' do
    json(params.to_h)
  end

  post '/echo' do
    json(params.to_h)
  end

  get '/ip' do
    env['REMOTE_ADDR']
  end

  get '/boom' do
    halt(500, 'server exploded')
  end

  get '/export' do
    stream do |out|
      out.write("id,name\n")
      out.write("1,alice\n")
      out.write("2,bob\n")
    end
  end
end

class IntegrationTestingTest < Minitest::Test
  include Facet::Testing::IntegrationTest
  integration_app IntegrationSampleApp

  def test_get_root
    get '/'
    assert_response :success
    assert_equal 'welcome', response.body
  end

  def test_dashboard_requires_login
    get '/dashboard'
    assert_response :unauthorized
  end

  def test_login_persists_session_cookie_across_requests
    post '/login', params: { user: { name: 'alice' } }
    assert_response :redirect
    assert_equal '/dashboard', response.location

    follow_redirect!
    assert_response :success
    assert_equal 'hello alice', response.body
  end

  def test_login_with_bad_credentials_stays_unauthorized
    post '/login', params: { user: { name: 'mallory' } }
    assert_response :unauthorized
  end

  def test_logout_clears_the_session
    post '/login', params: { user: { name: 'alice' } }
    follow_redirect!
    assert_response :success

    post '/logout'
    assert_response :redirect
    follow_redirect!

    get '/dashboard'
    assert_response :unauthorized
  end

  def test_get_params_are_parsed_with_bracket_nesting
    get '/echo', params: { q: 'hello world', filter: { tag: 'a' } }
    assert_response :success
    parsed = response.json
    assert_equal 'hello world', parsed['q']
    assert_equal 'a', parsed.dig('filter', 'tag')
  end

  def test_post_params_support_arrays
    post '/echo', params: { tags: %w[a b c] }
    assert_response :success
    assert_equal %w[a b c], response.json['tags']
  end

  def test_two_sessions_do_not_share_cookies
    browser_a = Facet::Testing::IntegrationSession.new(IntegrationSampleApp)
    browser_b = Facet::Testing::IntegrationSession.new(IntegrationSampleApp)

    browser_a.post('/login', params: { user: { name: 'alice' } })
    browser_a.follow_redirect!
    assert browser_a.response.success?

    response_b = browser_b.get('/dashboard')
    assert response_b.client_error?
    assert_equal 401, response_b.status
  end

  def test_follow_redirect_without_a_prior_redirect_raises
    get '/'
    error = assert_raises(RuntimeError) { follow_redirect! }
    assert_match(/no redirect to follow/, error.message)
  end

  def test_remote_addr_can_be_simulated_per_request
    get '/ip', remote_addr: '203.0.113.7'
    assert_equal '203.0.113.7', response.body

    get '/ip'
    assert_equal '127.0.0.1', response.body
  end

  def test_assert_response_accepts_integer_status
    get '/boom'
    assert_response 500
  end

  def test_assert_response_rejects_unknown_symbol
    get '/'
    assert_raises(ArgumentError) { assert_response(:teapot) }
  end

  def test_streaming_route_is_drained_into_the_response_body_in_order
    get '/export'
    assert_response :success
    assert_equal "id,name\n1,alice\n2,bob\n", response.body
  end
end
