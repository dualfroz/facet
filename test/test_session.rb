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

  def test_previous_secrets_still_decode_a_cookie_signed_under_a_retired_secret
    cookie = Prism::Session.encode({ 'user' => 'foksiu' }, 'old-secret')
    decoded = Prism::Session.decode(cookie, 'new-secret', previous_secrets: ['old-secret'])
    assert_equal 'foksiu', decoded['user']
  end

  def test_previous_secrets_do_not_accept_a_cookie_signed_under_neither_secret
    cookie = Prism::Session.encode({ 'user' => 'foksiu' }, 'unrelated-secret')
    decoded = Prism::Session.decode(cookie, 'new-secret', previous_secrets: ['old-secret'])
    assert_equal({}, decoded)
  end

  def test_encode_always_signs_under_the_current_secret_not_a_previous_one
    cookie = Prism::Session.encode({ 'user' => 'foksiu' }, 'new-secret')
    assert_equal({}, Prism::Session.decode(cookie, 'old-secret'))
    assert_equal 'foksiu', Prism::Session.decode(cookie, 'new-secret')['user']
  end
end
