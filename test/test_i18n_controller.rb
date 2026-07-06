require 'minitest/autorun'
require 'prism'
require 'support'

class GreetingsController < Prism::Controller
  def show
    html(t('hello'))
  end

  def remember
    session[:locale] = params['locale']
    html(t('hello'))
  end

  def stamp
    html(l(Time.utc(2026, 3, 5, 8, 30, 0)))
  end
end

class GreetingsApp < Prism::Application
  enable_sessions secret: 'i18n-controller-test-secret'

  get '/greet', to: 'greetings#show'
  get '/greet/remember', to: 'greetings#remember'
  get '/greet/stamp', to: 'greetings#stamp'
end

class I18nControllerTest < Minitest::Test
  include TestSupport

  def setup
    Prism::I18n.reset!
    Prism::I18n.store_translations(:en, 'hello' => 'Hello')
    Prism::I18n.store_translations(:pl, 'hello' => 'Czesc')
  end

  def teardown
    Prism::I18n.reset!
  end

  def call(method, path, **opts)
    GreetingsApp.call(env_for(method, path, **opts))
  end

  def test_defaults_to_default_locale_with_no_hints
    _, _, body = call('GET', '/greet')
    assert_equal 'Hello', body.join
  end

  def test_locale_query_param_overrides_default
    _, _, body = call('GET', '/greet?locale=pl')
    assert_equal 'Czesc', body.join
  end

  def test_unknown_locale_query_param_is_ignored
    _, _, body = call('GET', '/greet?locale=de')
    assert_equal 'Hello', body.join
  end

  def test_accept_language_header_is_used_when_no_param_given
    _, _, body = call('GET', '/greet', headers: { 'Accept-Language' => 'pl,en;q=0.5' })
    assert_equal 'Czesc', body.join
  end

  def test_locale_param_wins_over_accept_language_header
    _, _, body = call('GET', '/greet?locale=en', headers: { 'Accept-Language' => 'pl' })
    assert_equal 'Hello', body.join
  end

  def test_session_locale_is_sticky_across_requests
    status, headers, body = call('GET', '/greet/remember?locale=pl')
    assert_equal 200, status
    assert_equal 'Czesc', body.join
    line = headers['Set-Cookie'].split("\n").find { |c| c.start_with?('prism.session=') }
    cookie = line.split(';').first

    _, _, body = call('GET', '/greet', cookies: cookie)
    assert_equal 'Czesc', body.join
  end

  def test_localize_helper_formats_time_in_view
    _, _, body = call('GET', '/greet/stamp')
    assert_equal '2026-03-05 08:30:00', body.join
  end
end
