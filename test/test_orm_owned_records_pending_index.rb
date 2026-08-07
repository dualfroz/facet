require 'minitest/autorun'
require 'prism'
require 'tmpdir'

# The shape AccountController#moderation actually issues (examples/blog): find
# the ids of every record a user owns (an equality lookup on a foreign key,
# like Store#lookup_by_index), then filter a second table down to just the
# ones whose foreign key is IN that id list AND some other column equals a
# fixed value (Comment.pending.where(post_id: owned_post_ids) in the real
# app). That second query is an AndNode of a HashNode Array (IN-list) and a
# HashNode scalar (equality) - ConditionNode#indexed_candidates only tries
# lookup_by_index_in for a column actually present in #indexable_in_lists,
# so it is the post_id side (an Array) that must be indexed for this to
# avoid a scan; the leftover status equality is filtered from that already-
# narrow candidate set in memory afterward by Relation#rows, exactly the way
# OrmHasManyPolymorphicForeignKeyIndexTest proves for a two-column equality.
class OrmOwnedRecordsPendingIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-owned-pending-index-store')
    @store = CountingOwnedPendingIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:mod_owners, %w[id name])
    @store.create_table(:mod_posts, %w[id user_id title])
    @store.create_table(:mod_comments, %w[id post_id status body])

    owner_class = Class.new(Prism::Orm::Model) do
      table_name :mod_owners
      has_many :posts, class_name: 'ModPost', foreign_key: 'user_id'
    end
    post_class = Class.new(Prism::Orm::Model) { table_name :mod_posts }
    comment_class = Class.new(Prism::Orm::Model) { table_name :mod_comments }
    [owner_class, post_class, comment_class].each { |klass| klass.store = @store }
    Object.const_set(:ModOwner, owner_class)
    Object.const_set(:ModPost, post_class)
    Object.const_set(:ModComment, comment_class)

    @alice = ModOwner.create!(name: 'alice')
    @bob = ModOwner.create!(name: 'bob')
    @alice_post = ModPost.create!(user_id: @alice.id, title: 'alices post')
    @bob_post = ModPost.create!(user_id: @bob.id, title: 'bobs post')

    # 0 = pending, 1 = approved - plain integers here (not a real enum
    # module) since this test is only about index selection, not Enum's
    # label<->value translation, which already has its own coverage.
    ModComment.create!(post_id: @alice_post.id, status: 0, body: 'waiting on alice')
    ModComment.create!(post_id: @alice_post.id, status: 1, body: 'already approved')
    ModComment.create!(post_id: @bob_post.id, status: 0, body: 'waiting on bob')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[ModOwner ModPost ModComment].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_without_a_post_id_index_the_pending_lookup_falls_back_to_a_scan
    @store.reset_counts!
    bodies = ModComment.where(status: 0).where(post_id: [@alice_post.id]).to_a.map { |c| c['body'] }
    assert_equal ['waiting on alice'], bodies
    assert_equal 1, @store.scan_count
    assert_equal 0, @store.in_list_hits
  end

  def test_indexed_post_id_answers_the_in_list_and_filters_status_in_memory
    @store.add_index(:mod_comments, :post_id)

    @store.reset_counts!
    bodies = ModComment.where(status: 0).where(post_id: [@alice_post.id, @bob_post.id]).to_a.map { |c| c['body'] }.sort
    assert_equal ['waiting on alice', 'waiting on bob'], bodies,
      'the already-approved comment on the same post must be filtered out, not just deduped away'
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.in_list_hits
  end

  def test_an_owner_with_no_posts_yields_an_empty_in_list_without_scanning
    @store.add_index(:mod_posts, :user_id)
    @store.add_index(:mod_comments, :post_id)
    carol = ModOwner.create!(name: 'carol')

    @store.reset_counts!
    owned_ids = carol.posts.pluck('id')
    assert_equal [], owned_ids
    assert_equal 0, @store.scan_count, 'carol owns no posts, but that is still an index hit (zero rows), not a scan'

    bodies = ModComment.where(status: 0).where(post_id: owned_ids).to_a
    assert_equal [], bodies,
      'lookup_by_index_in on an empty Array is still an index hit (zero rows), not a fallback scan'
    assert_equal 0, @store.scan_count
  end

  def test_both_steps_of_the_real_controller_query_stay_index_backed_once_both_columns_are_indexed
    @store.add_index(:mod_posts, :user_id)
    @store.add_index(:mod_comments, :post_id)

    @store.reset_counts!
    owned_ids = @alice.posts.pluck('id')
    assert_equal [@alice_post.id], owned_ids

    bodies = ModComment.where(status: 0).where(post_id: owned_ids).to_a.map { |c| c['body'] }
    assert_equal ['waiting on alice'], bodies
    assert_equal 0, @store.scan_count, 'neither the owned-posts lookup nor the pending-comments lookup should scan'
  end
end

# Same wrapper shape as CountingFkIndexStore (test_orm_has_many_foreign_key_
# index.rb), extended with an IN-list hit counter since this file is
# specifically exercising Store#lookup_by_index_in rather than plain
# Store#lookup_by_index.
class CountingOwnedPendingIndexStore < Prism::Orm::Store
  attr_reader :scan_count, :in_list_hits

  def initialize(*args)
    super
    @scan_count = 0
    @in_list_hits = 0
  end

  def all(table)
    @scan_count += 1
    super
  end

  def lookup_by_index_in(table, column, values)
    result = super
    @in_list_hits += 1 unless result.nil?
    result
  end

  def reset_counts!
    @scan_count = 0
    @in_list_hits = 0
  end
end
