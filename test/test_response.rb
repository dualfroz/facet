require 'minitest/autorun'
require 'prism'

class ResponseTest < Minitest::Test
  def test_defaults
    status, headers, body = Prism::Response.new.finish
    assert_equal 200, status
    assert_equal 'text/html;charset=utf-8', headers['Content-Type']
    assert_equal [], body
  end

  def test_write
    response = Prism::Response.new
    response << 'a'
    response.write('b')
    assert_equal %w[a b], response.finish[2]
  end

  def test_set_cookie
    response = Prism::Response.new
    response.set_cookie('token', 'abc def')
    assert_includes response.headers['Set-Cookie'], 'token=abc+def'
    assert_includes response.headers['Set-Cookie'], 'HttpOnly'
  end

  def test_multiple_cookies
    response = Prism::Response.new
    response.set_cookie('a', '1')
    response.set_cookie('b', '2')
    assert_equal 2, response.headers['Set-Cookie'].split("\n").size
  end
end
