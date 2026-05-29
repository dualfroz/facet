require 'minitest/autorun'
require 'prism'

class SessionTest < Minitest::Test
  def test_roundtrip
    cookie = Prism::Session.encode({ 'user' => 'foksiu', 'count' => 3 }, 'top-secret')
    decoded = Prism::Session.decode(cookie, 'top-secret')
    assert_equal 'foksiu', decoded['user']
    assert_equal 3, decoded['count']
  end

  def test_tampering_rejected
    cookie = Prism::Session.encode({ 'admin' => false }, 'top-secret')
    payload, signature = cookie.split('--', 2)
    forged = "#{payload}--#{'0' * signature.size}"
    assert_equal({}, Prism::Session.decode(forged, 'top-secret'))
  end

  def test_wrong_secret
    cookie = Prism::Session.encode({ 'x' => 1 }, 'secret-a')
    assert_equal({}, Prism::Session.decode(cookie, 'secret-b'))
  end

  def test_cookie_is_url_safe
    cookie = Prism::Session.encode({ 'blob' => 'a' * 60 }, 's')
    assert_nil cookie[/[^A-Za-z0-9_\-]/], "expected url safe cookie, got: #{cookie}"
  end

  def test_missing_cookie
    assert_equal({}, Prism::Session.decode(nil, 's'))
    assert_equal({}, Prism::Session.decode('', 's'))
  end
end
