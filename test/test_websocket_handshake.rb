require 'minitest/autorun'
require 'prism'

class WebSocketHandshakeTest < Minitest::Test
  Handshake = Prism::WebSocket::Handshake

  # RFC 6455 section 1.3's worked example - the canonical regression test
  # for any Sec-WebSocket-Accept implementation.
  def test_accept_key_matches_the_rfc_6455_worked_example
    assert_equal 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', Handshake.accept_key('dGhlIHNhbXBsZSBub25jZQ==')
  end

  def test_request_recognizes_a_valid_upgrade_request
    env = {
      'REQUEST_METHOD' => 'GET',
      'HTTP_UPGRADE' => 'websocket',
      'HTTP_CONNECTION' => 'Upgrade',
      'HTTP_SEC_WEBSOCKET_KEY' => 'dGhlIHNhbXBsZSBub25jZQ=='
    }
    assert Handshake.request?(env)
  end

  def test_request_accepts_a_comma_separated_connection_header
    env = {
      'REQUEST_METHOD' => 'GET',
      'HTTP_UPGRADE' => 'websocket',
      'HTTP_CONNECTION' => 'keep-alive, Upgrade',
      'HTTP_SEC_WEBSOCKET_KEY' => 'dGhlIHNhbXBsZSBub25jZQ=='
    }
    assert Handshake.request?(env)
  end

  def test_request_rejects_a_plain_get
    env = { 'REQUEST_METHOD' => 'GET' }
    refute Handshake.request?(env)
  end

  def test_request_rejects_missing_upgrade_header
    env = { 'REQUEST_METHOD' => 'GET', 'HTTP_CONNECTION' => 'Upgrade', 'HTTP_SEC_WEBSOCKET_KEY' => 'x' }
    refute Handshake.request?(env)
  end

  def test_request_rejects_missing_sec_websocket_key
    env = { 'REQUEST_METHOD' => 'GET', 'HTTP_UPGRADE' => 'websocket', 'HTTP_CONNECTION' => 'Upgrade' }
    refute Handshake.request?(env)
  end

  def test_response_headers_include_the_computed_accept_value
    headers = Handshake.response_headers('HTTP_SEC_WEBSOCKET_KEY' => 'dGhlIHNhbXBsZSBub25jZQ==')
    assert_equal 'websocket', headers['Upgrade']
    assert_equal 'Upgrade', headers['Connection']
    assert_equal 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', headers['Sec-WebSocket-Accept']
  end
end
