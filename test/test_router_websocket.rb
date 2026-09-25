require 'minitest/autorun'
require 'facet'

class RouterWebSocketTest < Minitest::Test
  def setup
    @router = Facet::Router.new
  end

  def test_find_websocket_returns_the_registered_handler
    handler = Class.new
    @router.add_websocket('/cable', handler)
    assert_same handler, @router.find_websocket('/cable')
  end

  def test_find_websocket_returns_nil_for_an_unregistered_path
    assert_nil @router.find_websocket('/nope')
  end

  def test_websockets_are_exact_path_matches_not_prefixes
    handler = Class.new
    @router.add_websocket('/cable', handler)
    assert_nil @router.find_websocket('/cable/extra')
  end

  def test_registering_the_same_path_twice_replaces_the_handler
    first = Class.new
    second = Class.new
    @router.add_websocket('/cable', first)
    @router.add_websocket('/cable', second)
    assert_same second, @router.find_websocket('/cable')
  end

  def test_find_websocket_options_returns_an_empty_hash_for_an_unregistered_path
    assert_equal({}, @router.find_websocket_options('/nope'))
  end

  def test_find_websocket_options_returns_nil_max_message_size_by_default
    assert_nil @router.find_websocket_options('/nope')[:max_message_size]
  end

  def test_add_websocket_records_a_custom_max_message_size
    @router.add_websocket('/cable', Class.new, max_message_size: 4096)
    assert_equal 4096, @router.find_websocket_options('/cable')[:max_message_size]
  end
end
