require 'minitest/autorun'
require 'facet'
require 'support'

class WidgetsController < Facet::Controller
  def show
    respond_to do |format|
      format.html { html("<p>widget #{params['id']}</p>") }
      format.json { json(id: params['id'], kind: 'widget') }
    end
  end

  def flexible
    respond_to do |format|
      format.html { html('only html declared') }
    end
  end
end

class WidgetsApp < Facet::Application
  get '/widgets/:id', to: 'widgets#show', format: true
  get '/flexible', to: 'widgets#flexible', format: true
end

class RespondToTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    WidgetsApp.call(env_for(method, path, **opts))
  end

  def test_explicit_json_extension_wins_over_accept_header
    status, headers, body = call('GET', '/widgets/7.json', headers: { 'Accept' => 'text/html' })
    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal({ 'id' => '7', 'kind' => 'widget' }, JSON.parse(body.join))
  end

  def test_no_extension_falls_back_to_accept_header
    status, headers, body = call('GET', '/widgets/7', headers: { 'Accept' => 'application/json' })
    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal({ 'id' => '7', 'kind' => 'widget' }, JSON.parse(body.join))
  end

  def test_no_extension_no_accept_header_defaults_to_html
    status, headers, body = call('GET', '/widgets/7')
    assert_equal 200, status
    assert_includes headers['Content-Type'], 'text/html'
    assert_equal '<p>widget 7</p>', body.join
  end

  def test_unhandled_format_is_406
    status, = call('GET', '/flexible.json')
    assert_equal 406, status
  end
end
