require 'minitest/autorun'
require 'facet'

class SessionTest < Minitest::Test
  def test_roundtrip
    cookie = Facet::Session.encode({ 'user' => 'alice', 'count' => 3 }, 'top-secret')
    decoded = Facet::Session.decode(cookie, 'top-secret')
    assert_equal 'alice', decoded['user']
    assert_equal 3, decoded['count']
  end

  def test_tampering_rejected
    cookie = Facet::Session.encode({ 'admin' => false }, 'top-secret')
    payload, signature = cookie.split('--', 2)
    forged = "#{payload}--#{'0' * signature.size}"
    assert_equal({}, Facet::Session.decode(forged, 'top-secret'))
  end

  def test_wrong_secret
    cookie = Facet::Session.encode({ 'x' => 1 }, 'secret-a')
    assert_equal({}, Facet::Session.decode(cookie, 'secret-b'))
  end

  def test_cookie_is_url_safe
    cookie = Facet::Session.encode({ 'blob' => 'a' * 60 }, 's')
    assert_nil cookie[/[^A-Za-z0-9_\-]/], "expected url safe cookie, got: #{cookie}"
  end

  def test_missing_cookie
    assert_equal({}, Facet::Session.decode(nil, 's'))
    assert_equal({}, Facet::Session.decode('', 's'))
  end

  def test_previous_secrets_still_decode_a_cookie_signed_under_a_retired_secret
    cookie = Facet::Session.encode({ 'user' => 'alice' }, 'old-secret')
    decoded = Facet::Session.decode(cookie, 'new-secret', previous_secrets: ['old-secret'])
    assert_equal 'alice', decoded['user']
  end

  def test_previous_secrets_do_not_accept_a_cookie_signed_under_neither_secret
    cookie = Facet::Session.encode({ 'user' => 'alice' }, 'unrelated-secret')
    decoded = Facet::Session.decode(cookie, 'new-secret', previous_secrets: ['old-secret'])
    assert_equal({}, decoded)
  end

  def test_encode_always_signs_under_the_current_secret_not_a_previous_one
    cookie = Facet::Session.encode({ 'user' => 'alice' }, 'new-secret')
    assert_equal({}, Facet::Session.decode(cookie, 'old-secret'))
    assert_equal 'alice', Facet::Session.decode(cookie, 'new-secret')['user']
  end
end
