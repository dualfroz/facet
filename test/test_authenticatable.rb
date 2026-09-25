require 'minitest/autorun'
require 'facet'
require 'support'
require 'tmpdir'

class AuthSessionsController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser

  def create
    user = AuthUser.find_by(email: params['email'])
    if user && user.authenticate(params['password'])
      sign_in(user)
      halt(200, after_authentication_url)
    else
      halt(401, 'invalid credentials')
    end
  end

  def destroy
    sign_out
    halt(200, 'signed out')
  end
end

class AuthDashboardController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in'
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthApiController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthRememberSessionsController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, remember_cookie: :remember_token

  def create
    user = AuthUser.find_by(email: params['email'])
    if user && user.authenticate(params['password'])
      sign_in(user, remember: params['remember'] == '1')
      halt(200, 'signed in')
    else
      halt(401, 'invalid credentials')
    end
  end

  def destroy
    sign_out
    halt(200, 'signed out')
  end
end

class AuthRememberDashboardController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in', remember_cookie: :remember_token
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthBaseController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in'
end

class AuthInheritedController < AuthBaseController
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthMultiSessionsController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, remember_sessions: :AuthLoginSession

  def create
    user = AuthUser.find_by(email: params['email'])
    if user && user.authenticate(params['password'])
      sign_in(user, remember: params['remember'] == '1')
      halt(200, 'signed in')
    else
      halt(401, 'invalid credentials')
    end
  end

  def destroy
    sign_out
    halt(200, 'signed out')
  end
end

class AuthMultiDashboardController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in', remember_sessions: :AuthLoginSession
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end

  def other_devices
    halt(200, other_login_sessions.count.to_s)
  end

  def sign_out_others
    sign_out_all_other_sessions
    halt(200, other_login_sessions.count.to_s)
  end

  def revoke
    ok = revoke_login_session!(params['id'])
    halt(ok ? 200 : 404, ok ? 'revoked' : 'not found')
  end
end

class AuthCappedSessionsController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, remember_sessions: :AuthLoginSession, max_remember_sessions: 2

  def create
    user = AuthUser.find_by(email: params['email'])
    if user && user.authenticate(params['password'])
      sign_in(user, remember: true)
      halt(200, 'signed in')
    else
      halt(401, 'invalid credentials')
    end
  end
end

class AuthCappedDashboardController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in',
                     remember_sessions: :AuthLoginSession, max_remember_sessions: 2
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthZeroCappedSessionsController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, remember_sessions: :AuthLoginSession, max_remember_sessions: 0

  def create
    user = AuthUser.find_by(email: params['email'])
    if user && user.authenticate(params['password'])
      sign_in(user, remember: true)
      halt(200, 'signed in')
    else
      halt(401, 'invalid credentials')
    end
  end
end

class AuthZeroCappedDashboardController < Facet::Controller
  include Facet::Authenticatable
  authenticate_with model: :AuthUser, unauthenticated_redirect_path: '/sign_in',
                     remember_sessions: :AuthLoginSession, max_remember_sessions: 0
  before_action :require_authentication

  def index
    halt(200, "hello #{current_user.email}")
  end
end

class AuthenticatableApp < Facet::Application
  enable_sessions(secret: 'auth-secret')
  post '/sign_in', to: 'auth_sessions#create'
  post '/sign_out', to: 'auth_sessions#destroy'
  get '/dashboard', to: 'auth_dashboard#index'
  get '/api/me', to: 'auth_api#index'
  get '/inherited/me', to: 'auth_inherited#index'
  post '/remember/sign_in', to: 'auth_remember_sessions#create'
  post '/remember/sign_out', to: 'auth_remember_sessions#destroy'
  get '/remember/dashboard', to: 'auth_remember_dashboard#index'
  post '/multi/sign_in', to: 'auth_multi_sessions#create'
  post '/multi/sign_out', to: 'auth_multi_sessions#destroy'
  get '/multi/dashboard', to: 'auth_multi_dashboard#index'
  get '/multi/other_devices', to: 'auth_multi_dashboard#other_devices'
  post '/multi/sign_out_others', to: 'auth_multi_dashboard#sign_out_others'
  post '/multi/revoke/:id', to: 'auth_multi_dashboard#revoke'
  post '/capped/sign_in', to: 'auth_capped_sessions#create'
  get '/capped/dashboard', to: 'auth_capped_dashboard#index'
  post '/zero-capped/sign_in', to: 'auth_zero_capped_sessions#create'
  get '/zero-capped/dashboard', to: 'auth_zero_capped_dashboard#index'
end

class AuthenticatableTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('facet-authenticatable')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:auth_users, %w[id email password_digest remember_token])
    @store.create_table(:auth_login_sessions, %w[id user_id token user_agent ip_address])
    user_class = Class.new(Facet::Orm::Model) do
      table_name :auth_users
      has_secure_password
      has_secure_token :remember_token
    end
    user_class.store = @store
    Object.const_set(:AuthUser, user_class)

    login_session_class = Class.new(Facet::Orm::Model) do
      table_name :auth_login_sessions
      has_secure_token :token
    end
    login_session_class.store = @store
    Object.const_set(:AuthLoginSession, login_session_class)

    AuthUser.create!(email: 'alice@example.com', password: 'hunter2')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :AuthUser) if Object.const_defined?(:AuthUser)
    Object.send(:remove_const, :AuthLoginSession) if Object.const_defined?(:AuthLoginSession)
  end

  def call(method, path, **opts)
    AuthenticatableApp.call(env_for(method, path, **opts))
  end

  def session_cookie_from(headers)
    cookie_named(headers, 'facet.session')
  end

  def cookie_named(headers, name)
    line = headers['Set-Cookie'].split("\n").find { |c| c.start_with?("#{name}=") }
    line&.split(';')&.first
  end

  def sign_in_cookie
    _, headers, = call('POST', '/sign_in',
                        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                        body: 'email=alice@example.com&password=hunter2')
    session_cookie_from(headers)
  end

  def test_wrong_password_is_rejected
    status, = call('POST', '/sign_in',
                    headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                    body: 'email=alice@example.com&password=wrong')
    assert_equal 401, status
  end

  def test_dashboard_without_session_redirects_to_configured_path
    status, headers, = call('GET', '/dashboard')
    assert_equal 302, status
    assert_equal '/sign_in', headers['Location']
  end

  def test_api_without_session_halts_with_401
    status, = call('GET', '/api/me')
    assert_equal 401, status
  end

  def test_sign_in_then_dashboard_sees_current_user
    cookie = sign_in_cookie
    status, _, body = call('GET', '/dashboard', cookies: cookie)
    assert_equal 200, status
    assert_equal 'hello alice@example.com', body.join
  end

  def test_sign_out_forgets_current_user
    cookie = sign_in_cookie
    _, sign_out_headers, = call('POST', '/sign_out', cookies: cookie)
    fresh_cookie = session_cookie_from(sign_out_headers)

    status, = call('GET', '/dashboard', cookies: fresh_cookie)
    assert_equal 302, status
  end

  def test_return_to_url_is_remembered_across_the_redirect
    _, headers, = call('GET', '/dashboard')
    refute_nil headers['Location']
    cookie = session_cookie_from(headers)

    _, sign_in_headers, body = call('POST', '/sign_in',
                                     headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                     cookies: cookie,
                                     body: 'email=alice@example.com&password=hunter2')
    assert_equal '/dashboard', body.join
    refute_nil sign_in_headers['Set-Cookie']
  end

  def test_authenticate_with_declared_on_a_base_controller_redirects_a_subclass_without_a_session
    status, headers, = call('GET', '/inherited/me')
    assert_equal 302, status
    assert_equal '/sign_in', headers['Location']
  end

  def test_authenticate_with_declared_on_a_base_controller_sees_current_user_in_a_subclass
    cookie = sign_in_cookie
    status, _, body = call('GET', '/inherited/me', cookies: cookie)
    assert_equal 200, status
    assert_equal 'hello alice@example.com', body.join
  end

  def test_signing_in_without_remember_sets_no_remember_cookie
    _, headers, = call('POST', '/remember/sign_in',
                        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                        body: 'email=alice@example.com&password=hunter2')
    assert_nil cookie_named(headers, 'remember_token')
  end

  def test_remember_cookie_alone_survives_a_lost_session_cookie
    _, sign_in_headers, = call('POST', '/remember/sign_in',
                                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                body: 'email=alice@example.com&password=hunter2&remember=1')
    remember_cookie = cookie_named(sign_in_headers, 'remember_token')
    refute_nil remember_cookie

    status, dashboard_headers, body = call('GET', '/remember/dashboard', cookies: remember_cookie)
    assert_equal 200, status
    assert_equal 'hello alice@example.com', body.join
    refute_nil session_cookie_from(dashboard_headers)
  end

  def test_dashboard_rejects_a_request_with_no_cookies_at_all
    status, = call('GET', '/remember/dashboard')
    assert_equal 302, status
  end

  def test_dashboard_rejects_a_tampered_remember_cookie
    _, sign_in_headers, = call('POST', '/remember/sign_in',
                                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                body: 'email=alice@example.com&password=hunter2&remember=1')
    remember_cookie = cookie_named(sign_in_headers, 'remember_token')
    tampered = remember_cookie.sub('remember_token=', 'remember_token=tampered')

    status, = call('GET', '/remember/dashboard', cookies: tampered)
    assert_equal 302, status
  end

  def test_sign_out_rotates_the_token_so_the_old_remember_cookie_stops_working
    _, sign_in_headers, = call('POST', '/remember/sign_in',
                                headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                body: 'email=alice@example.com&password=hunter2&remember=1')
    remember_cookie = cookie_named(sign_in_headers, 'remember_token')
    session_cookie = session_cookie_from(sign_in_headers)

    call('POST', '/remember/sign_out', cookies: session_cookie)

    status, = call('GET', '/remember/dashboard', cookies: remember_cookie)
    assert_equal 302, status
  end

  def multi_sign_in(remember: true)
    _, headers, = call('POST', '/multi/sign_in',
                        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                        body: "email=alice@example.com&password=hunter2&remember=#{remember ? '1' : '0'}")
    headers
  end

  def test_remember_sessions_rejects_both_options_at_once
    error = assert_raises(ArgumentError) do
      Class.new(Facet::Controller) do
        include Facet::Authenticatable
        authenticate_with model: :AuthUser, remember_cookie: :remember_token, remember_sessions: :AuthLoginSession
      end
    end
    assert_match(/either remember_cookie: or remember_sessions:/, error.message)
  end

  def test_remember_sessions_creates_its_own_row_per_sign_in
    assert_equal 0, AuthLoginSession.count
    multi_sign_in
    assert_equal 1, AuthLoginSession.count
    assert_equal AuthUser.find_by(email: 'alice@example.com').id, AuthLoginSession.first.user_id
  end

  def test_remember_sessions_captures_user_agent_and_ip_when_the_model_has_those_columns
    env = env_for('POST', '/multi/sign_in',
                   headers: { 'Content-Type' => 'application/x-www-form-urlencoded', 'User-Agent' => 'DeviceScanner/9.0' },
                   body: 'email=alice@example.com&password=hunter2&remember=1')
    env['REMOTE_ADDR'] = '198.51.100.42'
    AuthenticatableApp.call(env)

    login_session = AuthLoginSession.first
    assert_equal 'DeviceScanner/9.0', login_session.user_agent
    assert_equal '198.51.100.42', login_session.ip_address
  end

  def test_remember_session_cookie_alone_survives_a_lost_session_cookie
    headers = multi_sign_in
    remember_cookie = cookie_named(headers, 'remember_session_token')
    refute_nil remember_cookie

    status, dashboard_headers, body = call('GET', '/multi/dashboard', cookies: remember_cookie)
    assert_equal 200, status
    assert_equal 'hello alice@example.com', body.join
    refute_nil session_cookie_from(dashboard_headers)
  end

  def test_two_remembered_browsers_are_independent_login_sessions
    browser_a = cookie_named(multi_sign_in, 'remember_session_token')
    browser_b = cookie_named(multi_sign_in, 'remember_session_token')
    refute_equal browser_a, browser_b
    assert_equal 2, AuthLoginSession.count

    status_a, = call('GET', '/multi/dashboard', cookies: browser_a)
    status_b, = call('GET', '/multi/dashboard', cookies: browser_b)
    assert_equal 200, status_a
    assert_equal 200, status_b
  end

  def test_signing_out_of_one_browser_leaves_the_other_remembered_browser_signed_in
    headers_a = multi_sign_in
    browser_a_remember = cookie_named(headers_a, 'remember_session_token')
    browser_a_session = session_cookie_from(headers_a)
    browser_b_remember = cookie_named(multi_sign_in, 'remember_session_token')

    call('POST', '/multi/sign_out', cookies: browser_a_session)

    status_a, = call('GET', '/multi/dashboard', cookies: browser_a_remember)
    assert_equal 302, status_a

    status_b, = call('GET', '/multi/dashboard', cookies: browser_b_remember)
    assert_equal 200, status_b
  end

  def test_other_login_sessions_excludes_the_current_browser
    browser_a_remember = cookie_named(multi_sign_in, 'remember_session_token')
    cookie_named(multi_sign_in, 'remember_session_token')
    cookie_named(multi_sign_in, 'remember_session_token')

    status, _, body = call('GET', '/multi/other_devices', cookies: browser_a_remember)
    assert_equal 200, status
    assert_equal '2', body.join
  end

  def test_sign_out_all_other_sessions_leaves_only_the_current_browser
    browser_a_remember = cookie_named(multi_sign_in, 'remember_session_token')
    browser_b_remember = cookie_named(multi_sign_in, 'remember_session_token')

    status, _, body = call('POST', '/multi/sign_out_others', cookies: browser_a_remember)
    assert_equal 200, status
    assert_equal '0', body.join
    assert_equal 1, AuthLoginSession.count

    status_b, = call('GET', '/multi/dashboard', cookies: browser_b_remember)
    assert_equal 302, status_b
    status_a, = call('GET', '/multi/dashboard', cookies: browser_a_remember)
    assert_equal 200, status_a
  end

  def test_revoke_login_session_by_id_signs_out_only_that_device
    browser_a_remember = cookie_named(multi_sign_in, 'remember_session_token')
    browser_b_remember = cookie_named(multi_sign_in, 'remember_session_token')
    browser_b_id = AuthLoginSession.order(:id, :desc).first.id

    status, _, body = call('POST', "/multi/revoke/#{browser_b_id}", cookies: browser_a_remember)
    assert_equal 200, status
    assert_equal 'revoked', body.join

    status_b, = call('GET', '/multi/dashboard', cookies: browser_b_remember)
    assert_equal 302, status_b
    status_a, = call('GET', '/multi/dashboard', cookies: browser_a_remember)
    assert_equal 200, status_a
  end

  def test_revoke_login_session_refuses_a_session_belonging_to_another_user
    AuthUser.create!(email: 'other@example.com', password: 'hunter2')
    other_login = AuthLoginSession.create!(user_id: AuthUser.find_by(email: 'other@example.com').id)
    browser_a_remember = cookie_named(multi_sign_in, 'remember_session_token')

    status, _, body = call('POST', "/multi/revoke/#{other_login.id}", cookies: browser_a_remember)
    assert_equal 404, status
    assert_equal 'not found', body.join
    refute_nil AuthLoginSession.find_by(id: other_login.id)
  end

  def test_revoking_the_current_login_session_signs_that_browser_out_too
    browser_a_remember = cookie_named(multi_sign_in, 'remember_session_token')
    current_id = AuthLoginSession.first.id

    call('POST', "/multi/revoke/#{current_id}", cookies: browser_a_remember)

    status, = call('GET', '/multi/dashboard', cookies: browser_a_remember)
    assert_equal 302, status
  end

  def test_signing_in_without_remember_does_not_set_a_remember_session_cookie
    headers = multi_sign_in(remember: false)
    assert_nil cookie_named(headers, 'remember_session_token')
    assert_equal 0, AuthLoginSession.count
  end

  def capped_sign_in
    _, headers, = call('POST', '/capped/sign_in',
                        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                        body: 'email=alice@example.com&password=hunter2')
    headers
  end

  def test_max_remember_sessions_requires_remember_sessions
    error = assert_raises(ArgumentError) do
      Class.new(Facet::Controller) do
        include Facet::Authenticatable
        authenticate_with model: :AuthUser, max_remember_sessions: 2
      end
    end
    assert_match(/max_remember_sessions: requires remember_sessions:/, error.message)
  end

  def test_under_the_limit_keeps_every_browser
    browser_a = cookie_named(capped_sign_in, 'remember_session_token')
    browser_b = cookie_named(capped_sign_in, 'remember_session_token')
    assert_equal 2, AuthLoginSession.count

    status_a, = call('GET', '/capped/dashboard', cookies: browser_a)
    status_b, = call('GET', '/capped/dashboard', cookies: browser_b)
    assert_equal 200, status_a
    assert_equal 200, status_b
  end

  def test_exceeding_the_limit_signs_out_the_oldest_browser_first
    browser_a = cookie_named(capped_sign_in, 'remember_session_token')
    browser_b = cookie_named(capped_sign_in, 'remember_session_token')
    browser_c = cookie_named(capped_sign_in, 'remember_session_token')

    assert_equal 2, AuthLoginSession.count

    status_a, = call('GET', '/capped/dashboard', cookies: browser_a)
    assert_equal 302, status_a, 'the oldest (first) browser should have been pruned'

    status_b, = call('GET', '/capped/dashboard', cookies: browser_b)
    status_c, = call('GET', '/capped/dashboard', cookies: browser_c)
    assert_equal 200, status_b
    assert_equal 200, status_c
  end

  def test_repeatedly_exceeding_the_limit_keeps_it_pinned_at_the_max
    5.times { capped_sign_in }
    assert_equal 2, AuthLoginSession.count
  end

  def zero_capped_sign_in
    call('POST', '/zero-capped/sign_in',
         headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
         body: 'email=alice@example.com&password=hunter2')
  end

  def test_max_remember_sessions_of_zero_prunes_the_row_it_just_created
    status, headers, = zero_capped_sign_in
    assert_equal 200, status
    assert_equal 0, AuthLoginSession.count,
                 'a limit of 0 must prune the just-created row too, not only rows older than it'

    session_cookie = session_cookie_from(headers)
    refute_nil session_cookie, 'sign_in always sets the plain session cookie regardless of the remember-row prune'
    status, = call('GET', '/zero-capped/dashboard', cookies: session_cookie)
    assert_equal 200, status, 'the session cookie set by this very sign_in must still authenticate the request'
  end

  def test_max_remember_sessions_of_zero_makes_the_remember_cookie_dead_on_arrival
    _, headers, = zero_capped_sign_in
    remember_cookie = cookie_named(headers, 'remember_session_token')
    refute_nil remember_cookie, 'sign_in(remember: true) sets the cookie unconditionally, before the prune runs'

    status, = call('GET', '/zero-capped/dashboard', cookies: remember_cookie)
    assert_equal 302, status, 'the remember cookie token matches no row once the limit-0 prune destroyed it'
  end
end
