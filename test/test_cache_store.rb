require 'minitest/autorun'
require 'facet'

class CacheStoreTest < Minitest::Test
  def setup
    @store = Facet::Cache::MemoryStore.new
  end

  def test_write_then_read_round_trips
    @store.write('key', 'value')
    assert_equal 'value', @store.read('key')
  end

  def test_read_of_missing_key_is_nil
    assert_nil @store.read('missing')
  end

  def test_keys_are_coerced_to_string
    @store.write(:sym_key, 'value')
    assert_equal 'value', @store.read('sym_key')
  end

  def test_fetch_computes_and_stores_on_miss
    calls = 0
    3.times { @store.fetch('k') { calls += 1; 'computed' } }
    assert_equal 1, calls
  end

  def test_fetch_returns_existing_value_without_yielding_on_hit
    @store.write('k', 'preset')
    result = @store.fetch('k') { raise 'must not be called' }
    assert_equal 'preset', result
  end

  def test_delete_removes_the_entry
    @store.write('k', 'v')
    assert @store.delete('k')
    assert_nil @store.read('k')
  end

  def test_delete_of_missing_key_returns_falsey
    refute @store.delete('missing')
  end

  def test_exist_reflects_presence
    refute @store.exist?('k')
    @store.write('k', 'v')
    assert @store.exist?('k')
  end

  def test_clear_empties_the_store
    @store.write('a', 1)
    @store.write('b', 2)
    @store.clear
    assert_equal 0, @store.size
  end

  def test_expires_in_makes_the_entry_unreadable_afterwards
    @store.write('k', 'v', expires_in: 0)
    sleep 0.01
    assert_nil @store.read('k')
  end

  def test_delete_matched_removes_keys_matching_a_regexp
    @store.write('posts/1', 'a')
    @store.write('posts/2', 'b')
    @store.write('users/1', 'c')
    @store.delete_matched(/\Aposts\//)
    assert_nil @store.read('posts/1')
    assert_nil @store.read('posts/2')
    assert_equal 'c', @store.read('users/1')
  end

  def test_default_store_is_a_memory_store_singleton
    assert_same Facet::Cache.store, Facet::Cache.store
    assert_instance_of Facet::Cache::MemoryStore, Facet::Cache.store
  end

  def test_unbounded_store_never_evicts
    store = Facet::Cache::MemoryStore.new
    50.times { |i| store.write("k#{i}", i) }
    assert_equal 50, store.size
  end

  def test_max_size_evicts_the_least_recently_used_entry_on_write
    store = Facet::Cache::MemoryStore.new(max_size: 2)
    store.write('a', 1)
    store.write('b', 2)
    store.write('c', 3)
    assert_equal 2, store.size
    assert_nil store.read('a')
    assert_equal 2, store.read('b')
    assert_equal 3, store.read('c')
  end

  def test_reading_a_key_protects_it_from_eviction
    store = Facet::Cache::MemoryStore.new(max_size: 2)
    store.write('a', 1)
    store.write('b', 2)
    store.read('a')
    store.write('c', 3)
    assert_equal 1, store.read('a')
    assert_nil store.read('b')
    assert_equal 3, store.read('c')
  end

  def test_rewriting_an_existing_key_does_not_grow_the_store
    store = Facet::Cache::MemoryStore.new(max_size: 2)
    store.write('a', 1)
    store.write('b', 2)
    store.write('a', 'updated')
    assert_equal 2, store.size
    assert_equal 'updated', store.read('a')
    assert_equal 2, store.read('b')
  end
end
