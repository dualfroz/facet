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

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_column_backfill_rebuilds_an_index_built_before_the_column_existed
    id1 = @store.insert(:posts, title: 'first')
    id2 = @store.insert(:posts, title: 'second')
    @store.add_index(:posts, :status)

    @store.add_column(:posts, :status, default: 'draft')

    matches = @store.lookup_by_index(:posts, { 'status' => 'draft' })
    refute_nil matches, 'the index should still cover the column after the backfill'
    assert_equal [id1, id2].sort, matches.map { |row| row['id'] }.sort
  end

  def test_add_column_backfill_drops_the_stale_nil_key_from_the_index
    @store.insert(:posts, title: 'first')
    @store.add_index(:posts, :status)

    @store.add_column(:posts, :status, default: 'draft')

    assert_equal [], @store.lookup_by_index(:posts, { 'status' => nil }),
                 'no row should still be indexed under the pre-backfill nil value'
  end

  def test_add_column_backfill_keeps_a_range_capable_index_usable
    id1 = @store.insert(:posts, title: 'first')
    id2 = @store.insert(:posts, title: 'second')
    @store.add_index(:posts, :priority)

    @store.add_column(:posts, :priority, default: 5)

    matches = @store.lookup_by_index_range(:posts, :priority, gte: 1)
    refute_nil matches
    assert_equal [id1, id2].sort, matches.map { |row| row['id'] }.sort
  end

  def test_remove_column_drops_a_single_column_index_covering_it
    @store.add_index(:posts, :status, name: 'idx_status')
    @store.remove_column(:posts, :status)

    assert_equal [], @store.indexes(:posts)
    assert_nil @store.lookup_by_index(:posts, { 'status' => 'draft' }),
               'a dropped column must never be reported as indexed again'
  end

  def test_remove_column_drops_a_composite_index_covering_it
    @store.add_column(:posts, :status, default: 'draft')
    @store.add_index(:posts, %i[title status])

    @store.remove_column(:posts, :title)

    assert_equal [], @store.indexes(:posts),
                 'a composite index cannot survive with one of its columns gone'
  end

  def test_remove_column_leaves_indexes_on_other_columns_untouched
    @store.add_column(:posts, :status, default: 'draft')
    @store.add_index(:posts, :title)
    @store.add_index(:posts, :status)

    @store.remove_column(:posts, :status)

    assert_equal ['index_posts_on_title'], @store.indexes(:posts).map { |index| index[:name] }
  end

  def test_remove_column_then_readding_it_starts_with_a_clean_index_free_slate
    id = @store.insert(:posts, title: 'first')
    @store.add_index(:posts, :status)
    @store.add_column(:posts, :status, default: 'draft')
    @store.remove_column(:posts, :status)

    @store.add_column(:posts, :status, default: 'archived')

    assert_equal [], @store.indexes(:posts),
                 'removing the column must have dropped the earlier index for good'
    assert_equal 'archived', @store.find(:posts, id)['status']
  end
end

class OrmIndexRangeStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-range-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:users, %w[id email age])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_single_column_index_is_range_capable_and_sorted
    @store.insert(:users, email: 'c@x.com', age: 30)
    @store.insert(:users, email: 'a@x.com', age: 10)
    @store.insert(:users, email: 'b@x.com', age: 20)
    @store.add_index(:users, :age)

    matches = @store.lookup_by_index_range(:users, :age, gte: 20)
    assert_equal [20, 30], matches.map { |row| row['age'] }.sort
  end

  def test_composite_index_is_never_range_capable
    @store.add_index(:users, [:email, :age])
    @store.insert(:users, email: 'a@x.com', age: 10)
    assert_nil @store.lookup_by_index_range(:users, :age, gte: 0)
  end

  def test_lookup_by_index_range_returns_nil_without_a_covering_index
    @store.insert(:users, email: 'a@x.com', age: 10)
    assert_nil @store.lookup_by_index_range(:users, :age, gte: 0)
  end

  def test_gte_is_inclusive
    @store.add_index(:users, :age)
    @store.insert(:users, email: 'a@x.com', age: 20)
    matches = @store.lookup_by_index_range(:users, :age, gte: 20)
    assert_equal 1, matches.size
  end

  def test_gt_is_exclusive
    @store.add_index(:users, :age)
    @store.insert(:users, email: 'a@x.com', age: 20)
    assert_equal [], @store.lookup_by_index_range(:users, :age, gt: 20)
  end

  def test_lte_is_inclusive
    @store.add_index(:users, :age)
    @store.insert(:users, email: 'a@x.com', age: 20)
    matches = @store.lookup_by_index_range(:users, :age, lte: 20)
    assert_equal 1, matches.size
  end

  def test_lt_is_exclusive
    @store.add_index(:users, :age)
    @store.insert(:users, email: 'a@x.com', age: 20)
    assert_equal [], @store.lookup_by_index_range(:users, :age, lt: 20)
  end

  def test_combined_lower_and_upper_bound
    @store.add_index(:users, :age)
    [5, 15, 25, 35, 45].each { |age| @store.insert(:users, email: "#{age}@x.com", age: age) }
    matches = @store.lookup_by_index_range(:users, :age, gte: 15, lte: 35)
    assert_equal [15, 25, 35], matches.map { |row| row['age'] }.sort
  end

  def test_nil_valued_rows_are_never_returned_by_a_range_lookup
    @store.add_index(:users, :age)
    @store.insert(:users, email: 'a@x.com', age: nil)
    @store.insert(:users, email: 'b@x.com', age: 10)
    matches = @store.lookup_by_index_range(:users, :age, gte: 0)
    assert_equal ['b@x.com'], matches.map { |row| row['email'] }
  end

  def test_index_backfilled_from_existing_rows_is_range_capable
    @store.insert(:users, email: 'a@x.com', age: 10)
    @store.insert(:users, email: 'b@x.com', age: 20)
    @store.add_index(:users, :age)
    matches = @store.lookup_by_index_range(:users, :age, gte: 15)
    assert_equal ['b@x.com'], matches.map { |row| row['email'] }
  end

