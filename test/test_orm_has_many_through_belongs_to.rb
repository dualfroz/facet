require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmHasManyThroughBelongsToTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-through-belongs-to-store')
    @store = CountingBelongsToThroughStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
    @store.create_table(:comments, %w[id post_id body])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id', dependent: :destroy
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id'
      has_many :co_comments, through: :post, source: :comments
    end
    [post_class, comment_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Comment, comment_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Comment].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_has_many_through_belongs_to_collects_source_records
    post = Post.create!(title: 'hello world')
    first = Comment.create!(post_id: post.id, body: 'first')
    second = Comment.create!(post_id: post.id, body: 'second')

    ids = first.co_comments.map(&:id).sort
    assert_equal [first.id, second.id].sort, ids
  end

  def test_has_many_through_belongs_to_scopes_to_own_post
    post_a = Post.create!(title: 'a')
    post_b = Post.create!(title: 'b')
    comment_a = Comment.create!(post_id: post_a.id, body: 'on a')
    Comment.create!(post_id: post_b.id, body: 'on b')

    assert_equal [comment_a.id], comment_a.co_comments.map(&:id)
  end

  def test_has_many_through_belongs_to_returns_empty_without_owner
    orphan = Comment.new(post_id: nil, body: 'no post')
    assert_equal [], orphan.co_comments
  end

  def test_includes_has_many_through_belongs_to_avoids_n_plus_one_queries
    3.times do |i|
      post = Post.create!(title: "post#{i}")
      2.times { |j| Comment.create!(post_id: post.id, body: "c#{i}-#{j}") }
    end

    @store.reset_query_count!
    comments = Comment.all.includes(:co_comments).to_a
    baseline = @store.query_count

    total = comments.sum { |comment| comment.co_comments.size }
    assert_equal baseline, @store.query_count,
      "expected preloaded #co_comments to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal 12, total
  end

  def test_includes_has_many_through_belongs_to_shares_one_through_record
    post = Post.create!(title: 'shared')
    Comment.create!(post_id: post.id, body: 'x')
    Comment.create!(post_id: post.id, body: 'y')

    @store.reset_query_count!
    comments = Comment.all.includes(:co_comments).to_a
    assert_equal 2, @store.query_count
    assert_equal [2, 2], comments.map { |comment| comment.co_comments.size }
  end
end

class CountingBelongsToThroughStore < Facet::Orm::Store
  def initialize(*)
    super
    @query_count = 0
  end

  attr_reader :query_count

  def reset_query_count!
    @query_count = 0
  end

  def all(table)
    @query_count += 1
    super
  end

  def find(table, id)
    @query_count += 1
    super
  end
end
