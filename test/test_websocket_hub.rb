require 'minitest/autorun'
require 'prism'

class WebSocketHubTest < Minitest::Test
  FakeConnection = Struct.new(:messages, :dead) do
    def initialize
      super([], false)
    end

    # Mirrors the real Connection#write_frame: a dead socket does not raise
    # out of write_text, it just silently marks itself closed - Hub relies
    # on that contract to notice and drop dead subscribers.
    def write_text(payload)
      return if dead
      messages << payload
    end

    def closed?
      dead
    end
  end

  def setup
    @hub = Prism::WebSocket::Hub.new
  end

  def test_broadcast_delivers_json_encoded_hash_to_every_subscriber
    a = FakeConnection.new
    b = FakeConnection.new
    @hub.subscribe('room_1', a)
    @hub.subscribe('room_1', b)

    @hub.broadcast('room_1', { event: 'ping', n: 1 })

    assert_equal ['{"event":"ping","n":1}'], a.messages
    assert_equal ['{"event":"ping","n":1}'], b.messages
  end

  def test_broadcast_sends_a_string_payload_verbatim
    connection = FakeConnection.new
    @hub.subscribe('room_1', connection)
    @hub.broadcast('room_1', 'raw text')
    assert_equal ['raw text'], connection.messages
  end

  def test_broadcast_only_reaches_subscribers_of_that_stream
    in_room = FakeConnection.new
    other_room = FakeConnection.new
    @hub.subscribe('room_1', in_room)
    @hub.subscribe('room_2', other_room)

    @hub.broadcast('room_1', 'hi')

    assert_equal ['hi'], in_room.messages
    assert_empty other_room.messages
  end

  def test_unsubscribe_removes_a_connection_from_future_broadcasts
    connection = FakeConnection.new
    @hub.subscribe('room_1', connection)
    @hub.unsubscribe('room_1', connection)
    @hub.broadcast('room_1', 'hi')
    assert_empty connection.messages
  end

  def test_unsubscribe_all_removes_a_connection_from_every_stream
    connection = FakeConnection.new
    @hub.subscribe('room_1', connection)
    @hub.subscribe('room_2', connection)
    @hub.unsubscribe_all(connection)

    assert_empty @hub.subscribers('room_1')
    assert_empty @hub.subscribers('room_2')
  end

  def test_subscribing_the_same_connection_twice_does_not_duplicate_deliveries
    connection = FakeConnection.new
    @hub.subscribe('room_1', connection)
    @hub.subscribe('room_1', connection)
    @hub.broadcast('room_1', 'once')
    assert_equal ['once'], connection.messages
  end

  def test_a_dead_connection_is_dropped_without_breaking_the_broadcast
    dead = FakeConnection.new
    dead.dead = true
    alive = FakeConnection.new
    @hub.subscribe('room_1', dead)
    @hub.subscribe('room_1', alive)

    @hub.broadcast('room_1', 'hi')

    assert_equal ['hi'], alive.messages
    assert_empty dead.messages
    refute_includes @hub.subscribers('room_1'), dead
  end

  def test_broadcast_and_subscribe_are_thread_safe_under_concurrency
    connections = Array.new(20) { FakeConnection.new }
    threads = connections.map do |connection|
      Thread.new do
        20.times { @hub.subscribe('hot_stream', connection) }
      end
    end
    threads.each(&:join)

    @hub.broadcast('hot_stream', 'go')

    connections.each { |connection| assert_equal ['go'], connection.messages }
    assert_equal 20, @hub.subscribers('hot_stream').size
  end

  def test_subscribe_without_a_cap_accepts_unlimited_subscribers
    10.times { |n| assert_equal true, @hub.subscribe('room_1', FakeConnection.new) }
    assert_equal 10, @hub.subscribers('room_1').size
  end

  def test_subscribe_rejects_a_new_connection_once_the_stream_is_at_capacity
    hub = Prism::WebSocket::Hub.new(max_subscribers_per_stream: 2)
    a = FakeConnection.new
    b = FakeConnection.new
    c = FakeConnection.new

    assert_equal true, hub.subscribe('room_1', a)
    assert_equal true, hub.subscribe('room_1', b)
    assert_equal false, hub.subscribe('room_1', c)

    assert_equal [a, b], hub.subscribers('room_1')
    hub.broadcast('room_1', 'hi')
    assert_empty c.messages
  end

  def test_subscribe_at_capacity_is_still_idempotent_for_an_existing_subscriber
    hub = Prism::WebSocket::Hub.new(max_subscribers_per_stream: 1)
    a = FakeConnection.new
    assert_equal true, hub.subscribe('room_1', a)
    # Re-subscribing the same connection must not be rejected just because
    # the stream is "full" - it was already counted once, this is a no-op.
    assert_equal true, hub.subscribe('room_1', a)
    assert_equal 1, hub.subscribers('room_1').size
  end

  def test_a_cap_is_scoped_to_one_stream_not_shared_across_streams
    hub = Prism::WebSocket::Hub.new(max_subscribers_per_stream: 1)
    assert_equal true, hub.subscribe('room_1', FakeConnection.new)
    assert_equal true, hub.subscribe('room_2', FakeConnection.new)
  end

  def test_unsubscribing_frees_a_slot_for_a_new_connection_to_take
    hub = Prism::WebSocket::Hub.new(max_subscribers_per_stream: 1)
    a = FakeConnection.new
    b = FakeConnection.new
    assert_equal true, hub.subscribe('room_1', a)
    assert_equal false, hub.subscribe('room_1', b)

    hub.unsubscribe('room_1', a)
    assert_equal true, hub.subscribe('room_1', b)
    assert_equal [b], hub.subscribers('room_1')
  end

  def test_capacity_is_enforced_correctly_under_concurrent_subscribe_attempts
    hub = Prism::WebSocket::Hub.new(max_subscribers_per_stream: 5)
    connections = Array.new(50) { FakeConnection.new }
    results = Array.new(50)
    threads = connections.each_with_index.map do |connection, i|
      Thread.new { results[i] = hub.subscribe('hot_stream', connection) }
    end
    threads.each(&:join)

    # Exactly 5 of the 50 concurrent attempts may have won a slot - not more
    # (the cap held under contention), not fewer (no lost wakeups/deadlock).
    assert_equal 5, results.count(true)
    assert_equal 5, hub.subscribers('hot_stream').size
  end
end
