require 'minitest/autorun'
require 'facet'
require 'support'

class MiddlewareParamsTest < Minitest::Test
  include TestSupport

  def setup
    @seen_env = nil
    downstream = lambda do |env|
      @seen_env = env
      [200, {}, ['ok']]
    end
    @app = Facet::Middleware::ParamsParser.new(downstream)
  end

  def test_valid_json_body_passes_through
    env = env_for('POST', '/echo', headers: { 'Content-Type' => 'application/json' }, body: '{"a":1}')
    status, = @app.call(env)
    assert_equal 200, status
  end

  def test_malformed_json_body_returns_400_before_reaching_app
    env = env_for('POST', '/echo', headers: { 'Content-Type' => 'application/json' }, body: '{not-json')
    status, headers, body = @app.call(env)
    assert_equal 400, status
    assert_equal 'application/json', headers['Content-Type']
    assert_includes JSON.parse(body.join)['error'], 'invalid JSON'
    assert_nil @seen_env, 'downstream app must not run on malformed body'
  end

  def test_downstream_can_still_read_the_body_after_validation
    env = env_for('POST', '/echo', headers: { 'Content-Type' => 'application/json' }, body: '{"a":1}')
    @app.call(env)
    assert_equal({ 'a' => 1 }, JSON.parse(@seen_env['rack.input'].read))
  end

  def test_non_json_body_is_left_alone
    env = env_for('POST', '/echo', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: 'a=1')
    status, = @app.call(env)
    assert_equal 200, status
  end
end
