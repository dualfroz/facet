require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-store')
    @path = File.join(@dir, 'test.pstore')
    @store = Prism::Orm::Store.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_table_and_insert
    @store.create_table(:users, %w[id name])
    id = @store.insert(:users, name: 'foksiu')
    assert_equal 1, id
    assert_equal({ 'id' => 1, 'name' => 'foksiu' }, @store.find(:users, 1))
  end

  def test_create_table_twice_raises
    @store.create_table(:users, %w[id name])
    assert_raises(Prism::Orm::Store::TableExists) { @store.create_table(:users, %w[id name]) }
  end

  def test_insert_assigns_incrementing_ids
    @store.create_table(:users, %w[id name])
    first = @store.insert(:users, name: 'a')
    second = @store.insert(:users, name: 'b')
    assert_equal 1, first
    assert_equal 2, second
  end

  def test_update_merges_attributes
    @store.create_table(:users, %w[id name role])
    id = @store.insert(:users, name: 'foksiu', role: 'admin')
    @store.update(:users, id, role: 'owner')
    row = @store.find(:users, id)
    assert_equal 'foksiu', row['name']
    assert_equal 'owner', row['role']
  end

  def test_update_missing_record_raises
    @store.create_table(:users, %w[id name])
    assert_raises(Prism::Orm::Store::RecordNotFound) { @store.update(:users, 999, name: 'nope') }
  end

  def test_delete_removes_row
    @store.create_table(:users, %w[id name])
    id = @store.insert(:users, name: 'foksiu')
    @store.delete(:users, id)
    assert_nil @store.find(:users, id)
  end

  def test_all_returns_every_row
    @store.create_table(:users, %w[id name])
    @store.insert(:users, name: 'a')
    @store.insert(:users, name: 'b')
    assert_equal ['a', 'b'], @store.all(:users).map { |row| row['name'] }
  end

  def test_count
    @store.create_table(:users, %w[id name])
    @store.insert(:users, name: 'a')
    @store.insert(:users, name: 'b')
    assert_equal 2, @store.count(:users)
  end

  def test_unknown_table_raises
    assert_raises(Prism::Orm::Store::UnknownTable) { @store.find(:ghosts, 1) }
  end

  def test_add_column_defaults_existing_rows
    @store.create_table(:users, %w[id name])
    id = @store.insert(:users, name: 'foksiu')
    @store.add_column(:users, :active, default: true)
    assert_equal true, @store.find(:users, id)['active']
    assert_includes @store.columns(:users), 'active'
  end

  def test_remove_column_strips_existing_rows
    @store.create_table(:users, %w[id name role])
    id = @store.insert(:users, name: 'foksiu', role: 'admin')
    @store.remove_column(:users, :role)
    refute @store.find(:users, id).key?('role')
    refute_includes @store.columns(:users), 'role'
  end

  def test_drop_table
    @store.create_table(:users, %w[id name])
    @store.drop_table(:users)
    refute @store.table_exists?(:users)
  end

  def test_migration_bookkeeping
    assert_empty @store.applied_migrations
    @store.record_migration('20260101000000')
    assert_equal ['20260101000000'], @store.applied_migrations
    @store.record_migration('20260101000000')
    assert_equal ['20260101000000'], @store.applied_migrations, 'recording twice must not duplicate'
    @store.forget_migration('20260101000000')
    assert_empty @store.applied_migrations
  end

  def test_insert_emits_sql_prism_event
    @store.create_table(:users, %w[id name])
    events = []
    subscriber = Prism::Instrumentation.subscribe('sql.prism') { |event| events << event }
    begin
      @store.insert(:users, name: 'foksiu')
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal 1, events.size
    assert_equal 'INSERT', events.first.payload[:operation]
    assert_equal 'users', events.first.payload[:table]
  end

  def test_find_and_all_and_count_emit_select_events
    @store.create_table(:users, %w[id name])
    id = @store.insert(:users, name: 'foksiu')
    events = []
    subscriber = Prism::Instrumentation.subscribe('sql.prism') { |event| events << event }
    begin
      @store.find(:users, id)
      @store.all(:users)
      @store.count(:users)
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal %w[SELECT SELECT], events.first(2).map { |e| e.payload[:operation] }
    assert_equal 'SELECT COUNT', events.last.payload[:operation]
  end

  def test_update_missing_record_still_emits_event_with_exception
    @store.create_table(:users, %w[id name])
    events = []
    subscriber = Prism::Instrumentation.subscribe('sql.prism') { |event| events << event }
    begin
      assert_raises(Prism::Orm::Store::RecordNotFound) { @store.update(:users, 999, name: 'nope') }
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal 1, events.size
    assert_equal 'Prism::Orm::Store::RecordNotFound', events.first.payload[:exception].first
  end

  def test_data_survives_reopening_the_store
    @store.create_table(:users, %w[id name])
    @store.insert(:users, name: 'persisted-foksiu')

    reopened = Prism::Orm::Store.new(@path)
    row = reopened.find(:users, 1)
    refute_nil row
    assert_equal 'persisted-foksiu', row['name']
  end
end
