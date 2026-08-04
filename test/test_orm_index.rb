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

  def test_range_lookup_tracks_updates
    @store.add_index(:users, :age)
    id = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.update(:users, id, age: 99)

    assert_equal [id], @store.lookup_by_index_range(:users, :age, gte: 90).map { |r| r['id'] }
    assert_equal [], @store.lookup_by_index_range(:users, :age, gte: 5, lte: 10)
  end

  def test_range_lookup_forgets_deleted_rows
    @store.add_index(:users, :age)
    id = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.delete(:users, id)
    assert_equal [], @store.lookup_by_index_range(:users, :age, gte: 0)
  end

  def test_reused_value_after_update_and_reinsert_still_resolves_correctly
    @store.add_index(:users, :age)
    a = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.insert(:users, email: 'b@x.com', age: 10)
    @store.update(:users, a, age: 50)

    assert_equal ['b@x.com'], @store.lookup_by_index_range(:users, :age, gte: 0, lte: 20).map { |r| r['email'] }
    assert_equal ['a@x.com'], @store.lookup_by_index_range(:users, :age, gte: 40).map { |r| r['email'] }
  end
end

# Covers Store#lookup_by_index_in - the IN-list lookup backing
# `where(column: [v1, v2, ...])`, most importantly `where(id: [...])`,
# which every belongs_to/has_one/has_many/has_many-through eager-load
# batches its preload query through (see Relation#preload_belongs_to and
# friends).
class OrmIndexInListStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-in-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:users, %w[id email age])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_id_lookup_needs_no_add_index_call_at_all
    a = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.insert(:users, email: 'b@x.com', age: 20)
    c = @store.insert(:users, email: 'c@x.com', age: 30)

    matches = @store.lookup_by_index_in(:users, :id, [a, c])
    assert_equal ['a@x.com', 'c@x.com'], matches.map { |row| row['email'] }.sort
  end

  def test_id_lookup_ignores_ids_that_do_not_exist
    a = @store.insert(:users, email: 'a@x.com', age: 10)
    matches = @store.lookup_by_index_in(:users, :id, [a, a + 1000])
    assert_equal [a], matches.map { |row| row['id'] }
  end

  def test_id_lookup_deduplicates_repeated_values
    a = @store.insert(:users, email: 'a@x.com', age: 10)
    matches = @store.lookup_by_index_in(:users, :id, [a, a, a])
    assert_equal 1, matches.size
  end

  def test_lookup_by_index_in_returns_nil_without_a_covering_index_on_a_non_id_column
    @store.insert(:users, email: 'a@x.com', age: 10)
    assert_nil @store.lookup_by_index_in(:users, :email, ['a@x.com'])
  end

  def test_lookup_by_index_in_uses_a_single_column_index_when_present
    @store.insert(:users, email: 'a@x.com', age: 10)
    @store.insert(:users, email: 'b@x.com', age: 20)
    @store.insert(:users, email: 'c@x.com', age: 30)
    @store.add_index(:users, :email)

    matches = @store.lookup_by_index_in(:users, :email, ['a@x.com', 'c@x.com'])
    assert_equal ['a@x.com', 'c@x.com'], matches.map { |row| row['email'] }.sort
  end

  def test_composite_index_cannot_answer_an_in_list_on_one_of_its_columns
    @store.add_index(:users, [:email, :age])
    @store.insert(:users, email: 'a@x.com', age: 10)
    assert_nil @store.lookup_by_index_in(:users, :email, ['a@x.com'])
  end

  def test_in_list_lookup_tracks_updates
    @store.add_index(:users, :email)
    id = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.update(:users, id, email: 'new@x.com')

    assert_equal [], @store.lookup_by_index_in(:users, :email, ['a@x.com'])
    assert_equal [id], @store.lookup_by_index_in(:users, :email, ['new@x.com']).map { |r| r['id'] }
  end

  def test_in_list_lookup_forgets_deleted_rows
    @store.add_index(:users, :email)
    id = @store.insert(:users, email: 'a@x.com', age: 10)
    @store.delete(:users, id)
    assert_equal [], @store.lookup_by_index_in(:users, :email, ['a@x.com'])
    assert_equal [], @store.lookup_by_index_in(:users, :id, [id])
  end

  def test_an_empty_values_list_matches_nothing_without_touching_the_table
    @store.insert(:users, email: 'a@x.com', age: 10)
    assert_equal [], @store.lookup_by_index_in(:users, :id, [])
  end
end

# Counts full-table scans (Store#all) separately from index lookups
# (Store#lookup_by_index that actually found a covering index), the same
# shape as CountingStore/CountingThroughStore used by the eager-loading
# tests, so Relation's index usage can be proven rather than assumed.
class CountingIndexStore < Prism::Orm::Store
  attr_reader :scan_count

  attr_reader :range_hits

  attr_reader :in_hits

  attr_reader :eq_range_hits

  def initialize(*args)
    super
    @scan_count = 0
    @index_hits = 0
    @range_hits = 0
    @in_hits = 0
    @eq_range_hits = 0
  end

  def all(table)
    @scan_count += 1
    super
  end

  def lookup_by_index(table, equalities)
    result = super
    @index_hits += 1 unless result.nil?
    result
  end

  def lookup_by_index_range(table, column, operators)
    result = super
    @range_hits += 1 unless result.nil?
    result
  end

  def lookup_by_index_in(table, column, values)
    result = super
    @in_hits += 1 unless result.nil?
    result
  end

  def lookup_by_index_equality_range(table, equalities, column, operators)
    result = super
    @eq_range_hits += 1 unless result.nil?
    result
  end

  def reset_counts!
    @scan_count = 0
    @index_hits = 0
    @range_hits = 0
    @in_hits = 0
    @eq_range_hits = 0
  end

  def index_hits
    @index_hits
  end
end

class OrmIndexRelationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-relation')
    @store = CountingIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title status])
    @store.add_index(:posts, :status)

    post_class = Class.new(Prism::Orm::Model) { table_name :posts }
    post_class.store = @store
    Object.const_set(:IndexedPost, post_class)

    IndexedPost.create!(title: 'a', status: 'draft')
    IndexedPost.create!(title: 'b', status: 'published')
    IndexedPost.create!(title: 'c', status: 'draft')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :IndexedPost) if Object.const_defined?(:IndexedPost)
  end

  def test_where_on_an_indexed_column_never_scans_the_full_table
    @store.reset_counts!
    results = IndexedPost.where(status: 'draft').to_a
    assert_equal ['a', 'c'], results.map { |post| post['title'] }.sort
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.index_hits
  end

  def test_where_on_an_unindexed_column_falls_back_to_a_full_scan
    @store.reset_counts!
    results = IndexedPost.where(title: 'a').to_a
    assert_equal ['a'], results.map { |post| post['title'] }
    assert_equal 1, @store.scan_count
    assert_equal 0, @store.index_hits
  end

  def test_chained_where_mixing_indexed_and_unindexed_columns_is_still_correct
    @store.reset_counts!
    results = IndexedPost.where(status: 'draft').where(title: 'c').to_a
    assert_equal ['c'], results.map { |post| post['title'] }
    assert_equal 0, @store.scan_count, 'the indexed equality should still narrow the candidate set'
  end

  def test_or_condition_cannot_use_the_index_but_is_still_correct
    @store.reset_counts!
    results = IndexedPost.where(status: 'draft').or(IndexedPost.where(title: 'b')).to_a
    assert_equal ['a', 'b', 'c'], results.map { |post| post['title'] }.sort
    assert_equal 1, @store.scan_count, 'an OR across columns cannot guarantee a single index key, so it must scan'
  end

  def test_find_by_uses_the_index
    @store.reset_counts!
    post = IndexedPost.find_by(status: 'published')
    assert_equal 'b', post['title']
    assert_equal 0, @store.scan_count
  end

  def test_or_condition_unions_index_hits_once_both_branches_are_indexed
    @store.add_index(:posts, :title)
    @store.reset_counts!

    results = IndexedPost.where(status: 'draft').or(IndexedPost.where(title: 'b')).to_a
    assert_equal ['a', 'b', 'c'], results.map { |post| post['title'] }.sort
    assert_equal 0, @store.scan_count, 'both branches are indexed, so the union must never fall back to a scan'
    assert_equal 2, @store.index_hits, 'one lookup per branch of the Or'
  end

  def test_or_condition_dedupes_a_row_matched_by_both_indexed_branches
    @store.add_index(:posts, :title)
    @store.reset_counts!

    # post "a" is status draft AND title "a" - both branches of the Or match
    # the same row, so the union must not return it twice.
    results = IndexedPost.where(status: 'draft').or(IndexedPost.where(title: 'a')).to_a
    assert_equal ['a', 'c'], results.map { |post| post['title'] }.sort
    assert_equal 2, results.size
    assert_equal 0, @store.scan_count
  end

  # `a.or(b).or(c)` builds OrNode(OrNode(a, b), c) - a left-nested tree, not
  # a flat three-way union. OrNode#indexed_candidates only recurses into
  # @left/@right, so this exercises that the recursion actually reaches the
  # innermost branch rather than treating the outer node's @left (itself an
  # OrNode) as an opaque leaf. Left untested since the index-union Or was
  # first added, per prism-postep.md "kierunki dalsze".
  def test_three_way_or_uses_the_index_on_every_branch
    @store.add_index(:posts, :title)
    IndexedPost.create!(title: 'd', status: 'published')
    @store.reset_counts!

    results = IndexedPost.where(status: 'draft')
                          .or(IndexedPost.where(title: 'b'))
                          .or(IndexedPost.where(title: 'd'))
                          .to_a
    assert_equal ['a', 'b', 'c', 'd'], results.map { |post| post['title'] }.sort
    assert_equal 0, @store.scan_count, 'every branch of the three-way Or is indexed, so it must never fall back to a scan'
    assert_equal 3, @store.index_hits, 'one lookup per branch, including the nested inner Or'
  end

  def test_three_way_or_falls_back_to_a_scan_when_one_branch_is_unindexed
    @store.reset_counts!

    # title carries no index in this test (unlike the one above), so the
    # whole union must scan rather than silently dropping that branch's
    # matches while still answering the other two from their indexes.
    results = IndexedPost.where(status: 'draft')
                          .or(IndexedPost.where(title: 'b'))
                          .or(IndexedPost.where(status: 'archived'))
                          .to_a
    assert_equal ['a', 'b', 'c'], results.map { |post| post['title'] }.sort
    assert_equal 1, @store.scan_count
  end
end

class OrmIndexRangeRelationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-range-relation')
    @store = CountingIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:products, %w[id name price])
    @store.add_index(:products, :price)

    product_class = Class.new(Prism::Orm::Model) { table_name :products }
    product_class.store = @store
    Object.const_set(:RangeIndexedProduct, product_class)

    RangeIndexedProduct.create!(name: 'cheap', price: 5)
    RangeIndexedProduct.create!(name: 'mid', price: 15)
    RangeIndexedProduct.create!(name: 'pricey', price: 25)
    RangeIndexedProduct.create!(name: 'luxury', price: 35)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :RangeIndexedProduct) if Object.const_defined?(:RangeIndexedProduct)
  end

  def test_gte_on_an_indexed_column_never_scans_the_full_table
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: { gte: 15 }).order(:price).to_a
    assert_equal %w[mid pricey luxury], results.map { |p| p['name'] }
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.range_hits
  end

  def test_combined_gte_and_lte_in_one_hash_uses_the_range_index
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: { gte: 10, lte: 30 }).order(:price).to_a
    assert_equal %w[mid pricey], results.map { |p| p['name'] }
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.range_hits
  end

  def test_a_ruby_range_value_uses_the_range_index
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: 10..30).order(:price).to_a
    assert_equal %w[mid pricey], results.map { |p| p['name'] }
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.range_hits
  end

  def test_an_exclusive_end_ruby_range_excludes_the_boundary
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: 15...25).to_a
    assert_equal ['mid'], results.map { |p| p['name'] }
    assert_equal 0, @store.scan_count
  end

  def test_two_chained_wheres_narrow_the_same_column_via_and
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: { gte: 10 }).where(price: { lte: 30 }).order(:price).to_a
    assert_equal %w[mid pricey], results.map { |p| p['name'] }
    assert_equal 0, @store.scan_count, 'the AND of two range clauses on the same column must still avoid a scan'
  end

  def test_a_hash_mixing_a_range_operator_with_a_non_range_operator_falls_back_to_a_scan
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: { gte: 10, ne: 25 }).order(:price).to_a
    assert_equal %w[mid luxury], results.map { |p| p['name'] }
    assert_equal 1, @store.scan_count, ':ne cannot be expressed as a contiguous bound, so this must be a full scan'
    assert_equal 0, @store.range_hits
  end

  def test_or_across_columns_still_falls_back_to_a_scan_when_only_one_side_is_indexed
    @store.reset_counts!
    results = RangeIndexedProduct.where(price: { gte: 30 }).or(RangeIndexedProduct.where(name: 'cheap')).to_a
    assert_equal %w[cheap luxury], results.map { |p| p['name'] }.sort
    assert_equal 1, @store.scan_count, 'name has no index, so OrNode cannot union candidates from both sides'
    # The price side IS individually range-indexed, and OrNode#indexed_candidates
    # tries it before discovering the name side has no covering index at all -
    # that one probe is cheap (an O(log n) index lookup, not a scan) and its
    # result is simply discarded once the other side comes back nil.
    assert_equal 1, @store.range_hits
  end
end

class OrmIndexInListRelationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-in-relation')
    @store = CountingIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id sku status])
    @store.add_index(:widgets, :sku)

    widget_class = Class.new(Prism::Orm::Model) { table_name :widgets }
    widget_class.store = @store
    Object.const_set(:InListWidget, widget_class)

    @a = InListWidget.create!(sku: 'AAA', status: 'active')
    @b = InListWidget.create!(sku: 'BBB', status: 'active')
    @c = InListWidget.create!(sku: 'CCC', status: 'retired')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :InListWidget) if Object.const_defined?(:InListWidget)
  end

  def test_where_id_in_never_scans_even_with_no_add_index_call_for_id
    @store.reset_counts!
    results = InListWidget.where(id: [@a.id, @c.id]).to_a
    assert_equal %w[AAA CCC], results.map { |w| w['sku'] }.sort
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.in_hits
  end

  def test_where_on_an_in_indexed_column_never_scans
    @store.reset_counts!
    results = InListWidget.where(sku: %w[AAA CCC]).to_a
    assert_equal %w[AAA CCC], results.map { |w| w['sku'] }.sort
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.in_hits
  end

  def test_where_on_an_unindexed_column_in_list_falls_back_to_a_scan
    @store.reset_counts!
    results = InListWidget.where(status: ['retired']).to_a
    assert_equal ['CCC'], results.map { |w| w['sku'] }
    assert_equal 1, @store.scan_count
    assert_equal 0, @store.in_hits
  end

  def test_unknown_ids_are_silently_dropped_not_nil_rows
    @store.reset_counts!
    results = InListWidget.where(id: [@a.id, @a.id + 999]).to_a
    assert_equal [@a.id], results.map(&:id)
  end

  def test_two_chained_id_in_wheres_intersect_instead_of_scanning
    @store.reset_counts!
    results = InListWidget.where(id: [@a.id, @b.id, @c.id]).where(id: [@b.id, @c.id]).to_a
    assert_equal [@b.id, @c.id].sort, results.map(&:id).sort
    assert_equal 0, @store.scan_count
  end

  def test_an_equality_condition_alongside_an_id_in_list_still_uses_an_index_and_stays_correct
    @store.reset_counts!
    results = InListWidget.where(id: [@a.id, @b.id, @c.id]).where(sku: 'BBB').to_a
    assert_equal ['BBB'], results.map { |w| w['sku'] }
    assert_equal 0, @store.scan_count
  end
end

class OrmIndexEqualityRangeStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-eq-range-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id featured position])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_returns_nil_without_a_covering_composite_index
    @store.insert(:posts, featured: true, position: 1)
    assert_nil @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position, gte: 0)
  end

  def test_a_single_column_index_on_the_range_column_alone_does_not_cover_it
    @store.add_index(:posts, :position)
    @store.insert(:posts, featured: true, position: 1)
    assert_nil @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position, gte: 0)
  end

  def test_finds_rows_within_the_prefix_and_bounds
    @store.add_index(:posts, %i[featured position])
    @store.insert(:posts, featured: true, position: 1)
    @store.insert(:posts, featured: true, position: 2)
    @store.insert(:posts, featured: true, position: 3)
    @store.insert(:posts, featured: false, position: 1)

    matches = @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position, lt: 3)
    assert_equal [1, 2], matches.map { |row| row['position'] }.sort
  end

  def test_equality_key_order_from_the_caller_does_not_matter
    wide = Prism::Orm::Store.new(File.join(@dir, 'order.pstore'))
    wide.create_table(:tasks, %w[id project priority position])
    wide.add_index(:tasks, %i[project priority position])
    wide.insert(:tasks, project: 'a', priority: 'high', position: 1)
    wide.insert(:tasks, project: 'a', priority: 'high', position: 2)

    declared_order = wide.lookup_by_index_equality_range(:tasks, { project: 'a', priority: 'high' }, :position, gte: 0)
    reversed_order = wide.lookup_by_index_equality_range(:tasks, { priority: 'high', project: 'a' }, :position, gte: 0)
    assert_equal [1, 2], declared_order.map { |row| row['position'] }.sort
    assert_equal declared_order.map { |row| row['id'] }.sort, reversed_order.map { |row| row['id'] }.sort
  end

  def test_backfills_from_existing_rows
    @store.insert(:posts, featured: true, position: 1)
    @store.insert(:posts, featured: true, position: 2)
    @store.add_index(:posts, %i[featured position])

    matches = @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position, gte: 2)
    assert_equal [2], matches.map { |row| row['position'] }
  end

  def test_tracks_inserts_updates_and_deletes
    @store.add_index(:posts, %i[featured position])
    a = @store.insert(:posts, featured: true, position: 1)
    @store.insert(:posts, featured: true, position: 2)

    assert_equal [1, 2], @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position,
                                                                gte: 0).map { |r| r['position'] }.sort

    @store.update(:posts, a, position: 9)
    assert_equal [2, 9], @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position,
                                                                gte: 0).map { |r| r['position'] }.sort

    @store.delete(:posts, a)
    assert_equal [2], @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position,
                                                             gte: 0).map { |r| r['position'] }
  end

  def test_switching_the_prefix_value_moves_a_row_to_the_other_partition
    @store.add_index(:posts, %i[featured position])
    id = @store.insert(:posts, featured: true, position: 1)

    @store.update(:posts, id, featured: false)
    assert_equal [], @store.lookup_by_index_equality_range(:posts, { 'featured' => true }, :position, gte: 0)
    assert_equal [1], @store.lookup_by_index_equality_range(:posts, { 'featured' => false }, :position,
                                                             gte: 0).map { |r| r['position'] }
  end

  def test_an_unknown_prefix_value_matches_nothing_without_a_scan
    @store.add_index(:posts, %i[featured position])
    @store.insert(:posts, featured: true, position: 1)

    assert_equal [], @store.lookup_by_index_equality_range(:posts, { 'featured' => 'nonexistent' }, :position, gte: 0)
  end

  def test_a_three_column_composite_index_still_works_with_a_two_column_prefix
    @store = Prism::Orm::Store.new(File.join(@dir, 'wide.pstore'))
    @store.create_table(:tasks, %w[id project priority position])
    @store.add_index(:tasks, %i[project priority position])
    @store.insert(:tasks, project: 'a', priority: 'high', position: 1)
    @store.insert(:tasks, project: 'a', priority: 'high', position: 2)
    @store.insert(:tasks, project: 'a', priority: 'low', position: 1)

    matches = @store.lookup_by_index_equality_range(:tasks, { project: 'a', priority: 'high' }, :position, gte: 0)
    assert_equal [1, 2], matches.map { |row| row['position'] }.sort
  end

  def test_lookup_by_index_range_still_refuses_a_composite_index_unchanged_behavior
    @store.add_index(:posts, %i[featured position])
    @store.insert(:posts, featured: true, position: 1)
    assert_nil @store.lookup_by_index_range(:posts, :position, gte: 0)
  end

  # A paranoid model's Model.all already carries `where(deleted_at: nil)`
  # before any caller-added `.where(featured: ...)` - real regression this
  # session's blog_demo.rb run caught: the index prefix is only `featured`,
  # so `equalities` legitimately arrives with an EXTRA column
  # (`deleted_at`) the index knows nothing about. That must still resolve
  # through the index (using only the subset it actually covers), not fall
  # back to a scan just because the caller happened to also constrain an
  # unrelated column.
  def test_an_equality_column_outside_the_index_prefix_does_not_block_the_lookup
    @store.add_index(:posts, %i[featured position])
    @store.insert(:posts, featured: true, position: 1, deleted_at: nil)
    @store.insert(:posts, featured: true, position: 5, deleted_at: nil)

    matches = @store.lookup_by_index_equality_range(:posts, { 'deleted_at' => nil, 'featured' => true },
                                                      :position, lt: 3)
    assert_equal [1], matches.map { |row| row['position'] }
  end

  def test_the_most_specific_covering_composite_index_wins_when_several_could_answer
    wide = Prism::Orm::Store.new(File.join(@dir, 'multi.pstore'))
    wide.create_table(:tasks, %w[id project priority position])
    wide.add_index(:tasks, %i[project position])
    wide.add_index(:tasks, %i[project priority position])
    wide.insert(:tasks, project: 'a', priority: 'high', position: 1)
    wide.insert(:tasks, project: 'a', priority: 'low', position: 2)

    matches = wide.lookup_by_index_equality_range(:tasks, { project: 'a', priority: 'high' }, :position, gte: 0)
    assert_equal [1], matches.map { |row| row['position'] },
                 'the 3-column index covering priority too should be preferred over the 2-column one'
  end
end

class OrmIndexEqualityRangeRelationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-index-eq-range-relation')
    @store = CountingIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id featured position])
    @store.add_index(:posts, %i[featured position])

    post_class = Class.new(Prism::Orm::Model) { table_name :posts }
    post_class.store = @store
    Object.const_set(:EqRangeIndexedPost, post_class)

    EqRangeIndexedPost.create!(featured: true, position: 1)
    EqRangeIndexedPost.create!(featured: true, position: 2)
    EqRangeIndexedPost.create!(featured: true, position: 3)
    EqRangeIndexedPost.create!(featured: false, position: 1)
    EqRangeIndexedPost.create!(featured: false, position: 2)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :EqRangeIndexedPost) if Object.const_defined?(:EqRangeIndexedPost)
  end

  def test_two_chained_wheres_scope_equality_then_range_never_scan
    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: true).where(position: { lt: 3 }).order(:position).to_a
    assert_equal [1, 2], results.map { |p| p['position'] }
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.eq_range_hits
  end

  def test_single_where_with_both_conditions_in_one_hash_never_scans
    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: true, position: { gte: 2 }).to_a
    assert_equal [2, 3], results.map { |p| p['position'] }.sort
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.eq_range_hits
  end

  def test_a_ruby_range_value_alongside_an_equality_uses_the_composite_index
    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: false).where(position: 1..1).to_a
    assert_equal [1], results.map { |p| p['position'] }
    assert_equal 0, @store.scan_count
  end

  def test_the_other_scope_partition_is_unaffected_by_the_first
    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: false).where(position: { gte: 0 }).to_a
    assert_equal [1, 2], results.map { |p| p['position'] }.sort
    assert_equal 0, @store.scan_count
  end

  def test_range_without_any_equality_falls_back_to_a_scan_not_the_composite_index
    # This fixture only has the composite [featured, position] index, no
    # standalone index on position - a bare range with no equality column
    # to pair with can use neither the plain range path (single-column
    # only) nor the composite one (needs an equality prefix), so a scan is
    # the correct, honest answer here, not a false "it found an index".
    @store.reset_counts!
    results = EqRangeIndexedPost.where(position: { gte: 3 }).to_a
    assert_equal [3], results.map { |p| p['position'] }
    assert_equal 1, @store.scan_count
    assert_equal 0, @store.eq_range_hits, 'no equality column means no composite prefix to look up'
  end

  def test_equality_without_any_range_falls_back_to_a_scan_not_the_composite_index
    # Same reasoning as above, mirrored: this fixture has no standalone
    # index on featured either, only the composite - a bare equality with
    # no range column to pair with can't use a composite index that
    # requires ALL its columns pinned (see Store#lookup_by_index), so this
    # is a scan too, not a spurious composite hit.
    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: true).to_a
    assert_equal 3, results.size
    assert_equal 1, @store.scan_count
    assert_equal 0, @store.eq_range_hits
  end

  def test_reflects_a_reorder_through_the_underlying_model
    post = EqRangeIndexedPost.where(featured: true).where(position: 1).first
    post.class.store.increment_counter(post.class.table_name, post.id, 'position', 10)

    @store.reset_counts!
    results = EqRangeIndexedPost.where(featured: true).where(position: { lt: 3 }).to_a
    assert_equal [2], results.map { |p| p['position'] }
    assert_equal 0, @store.scan_count
  end
end
