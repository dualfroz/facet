require 'minitest/autorun'
require 'prism'
require 'support'

class RequestTest < Minitest::Test
  include TestSupport

  def test_query_params
    request = Prism::Request.new(env_for('GET', '/s?q=ruby&page=3'))
    assert_equal 'ruby', request.params['q']
    assert_equal '3', request.params['page']
  end

  def test_json_body
    payload = JSON.generate(name: 'foksiu', role: 'admin')
    request = Prism::Request.new(env_for('POST', '/u', headers: { 'Content-Type' => 'application/json' }, body: payload))
    assert_equal 'foksiu', request.params['name']
    assert_equal 'admin', request.params[:role]
  end

  def test_form_body
    request = Prism::Request.new(env_for('POST', '/u', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: 'a=1&b=two'))
    assert_equal '1', request.params['a']
    assert_equal 'two', request.params['b']
  end

  def test_cookies
    request = Prism::Request.new(env_for('GET', '/', cookies: 'foo=bar; baz=qux'))
    assert_equal 'bar', request.cookies['foo']
    assert_equal 'qux', request.cookies['baz']
  end

  def test_headers
    request = Prism::Request.new(env_for('GET', '/', headers: { 'X-Custom' => 'yes' }))
    assert_equal 'yes', request.headers['X-Custom']
  end

  def test_params_precedence
    env = env_for('POST', '/x?id=query',
                  headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                  body: 'id=body')
    request = Prism::Request.new(env)
    request.path_params = { 'id' => 'path' }
    assert_equal 'path', request.params['id']
  end
end
