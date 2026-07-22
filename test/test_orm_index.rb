require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmIndexStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:users, %w[id email age])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_index_returns_a_default_name_and_lists_it
    name = @store.add_index(:users, :email)
    assert_equal 'index_users_on_email', name
    assert_equal [{ name: 'index_users_on_email', columns: ['email'], unique: false }], @store.indexes(:users)
  end

  def test_add_index_accepts_an_explicit_name
    name = @store.add_index(:users, :email, name: 'idx_email')
    assert_equal 'idx_email', name
  end

  def test_add_index_twice_with_the_same_name_raises
    @store.add_index(:users, :email)
    assert_raises(Prism::Orm::Store::IndexExists) { @store.add_index(:users, :email) }
  end

  def test_add_index_backfills_existing_rows
    @store.insert(:users, email: 'a@x.com', age: 20)
    @store.insert(:users, email: 'b@x.com', age: 30)
    @store.add_index(:users, :email)

    matches = @store.lookup_by_index(:users, { 'email' => 'a@x.com' })
    assert_equal ['a@x.com'], matches.map { |row| row['email'] }
  end

  def test_add_unique_index_over_existing_duplicates_raises_and_creates_nothing
    @store.insert(:users, email: 'dup@x.com', age: 20)
    @store.insert(:users, email: 'dup@x.com', age: 30)

    assert_raises(Prism::Orm::Store::UniqueConstraintViolation) do
      @store.add_index(:users, :email, unique: true)
    end
    assert_equal [], @store.indexes(:users)
  end

  def test_remove_index_by_name
    @store.add_index(:users, :email, name: 'idx_email')
    @store.remove_index(:users, 'idx_email')
    assert_equal [], @store.indexes(:users)
  end

  def test_remove_index_by_column_list
    @store.add_index(:users, :email)
    @store.remove_index(:users, :email)
    assert_equal [], @store.indexes(:users)
  end

  def test_remove_unknown_index_raises
    assert_raises(Prism::Orm::Store::UnknownIndex) { @store.remove_index(:users, :email) }
  end

  def test_lookup_by_index_returns_nil_without_a_covering_index
    @store.insert(:users, email: 'a@x.com', age: 20)
    assert_nil @store.lookup_by_index(:users, { 'email' => 'a@x.com' })
  end

  def test_lookup_by_index_returns_empty_array_for_no_match
    @store.add_index(:users, :email)
    @store.insert(:users, email: 'a@x.com', age: 20)
    assert_equal [], @store.lookup_by_index(:users, { 'email' => 'nobody@x.com' })
  end

  def test_composite_index_requires_every_column_present_in_the_lookup
    @store.add_index(:users, [:email, :age])
    @store.insert(:users, email: 'a@x.com', age: 20)

    assert_nil @store.lookup_by_index(:users, { 'email' => 'a@x.com' }),
               'a lookup missing one of the composite columns should not use this index'
    matches = @store.lookup_by_index(:users, { 'email' => 'a@x.com', 'age' => 20 })
    assert_equal 1, matches.size
  end

  def test_lookup_by_index_prefers_the_most_specific_covering_index
    @store.add_index(:users, :email)
    @store.add_index(:users, [:email, :age])
    @store.insert(:users, email: 'a@x.com', age: 20)
    @store.insert(:users, email: 'a@x.com', age: 99)

    matches = @store.lookup_by_index(:users, { 'email' => 'a@x.com', 'age' => 20 })
    assert_equal [20], matches.map { |row| row['age'] }
  end

  def test_unique_index_rejects_a_duplicate_insert
    @store.add_index(:users, :email, unique: true)
    @store.insert(:users, email: 'a@x.com', age: 20)

    assert_raises(Prism::Orm::Store::UniqueConstraintViolation) do
      @store.insert(:users, email: 'a@x.com', age: 30)
    end
    assert_equal 1, @store.count(:users), 'the rejected insert must not have partially applied'
  end

  def test_unique_index_rejects_an_update_that_collides_with_another_row
    @store.add_index(:users, :email, unique: true)
    id1 = @store.insert(:users, email: 'a@x.com', age: 20)
    id2 = @store.insert(:users, email: 'b@x.com', age: 30)

    assert_raises(Prism::Orm::Store::UniqueConstraintViolation) do
      @store.update(:users, id2, email: 'a@x.com')
    end
    assert_equal 'b@x.com', @store.find(:users, id2)['email'], 'the rejected update must not have partially applied'
    assert_equal 'a@x.com', @store.find(:users, id1)['email']
  end

  def test_unique_index_allows_updating_a_row_to_its_own_current_value
    @store.add_index(:users, :email, unique: true)
    id = @store.insert(:users, email: 'a@x.com', age: 20)
    @store.update(:users, id, age: 21)
    assert_equal 21, @store.find(:users, id)['age']
  end

  def test_index_tracks_updates_old_key_freed_new_key_claimed
    @store.add_index(:users, :email)
    id = @store.insert(:users, email: 'a@x.com', age: 20)
    @store.update(:users, id, email: 'b@x.com')

    assert_equal [], @store.lookup_by_index(:users, { 'email' => 'a@x.com' })
    assert_equal [id], @store.lookup_by_index(:users, { 'email' => 'b@x.com' }).map { |row| row['id'] }
  end

  def test_index_forgets_deleted_rows
    @store.add_index(:users, :email)
    id = @store.insert(:users, email: 'a@x.com', age: 20)
    @store.delete(:users, id)
    assert_equal [], @store.lookup_by_index(:users, { 'email' => 'a@x.com' })
  end

  def test_deleting_a_nonexistent_id_is_still_a_silent_no_op
    @store.add_index(:users, :email)
    @store.delete(:users, 999)
  end
end

# add_column/remove_column must keep any index that covers the affected
# column in sync - see the comments on Store#add_column/#remove_column for
# why a stale map here is a silent-wrong-results bug (Relation#rows trusts
# a non-nil #lookup_by_index result as definitive), not just a missed
# optimization.
class OrmIndexColumnMigrationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-column-migration')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
  end

