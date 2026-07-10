require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmHasManyThroughTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-through-store')
    @store = CountingThroughStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
    @store.create_table(:commenters, %w[id name])
    @store.create_table(:comments, %w[id post_id commenter_id body])

    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id', dependent: :destroy
      has_many :commenters, through: :comments, source: :commenter
    end
    commenter_class = Class.new(Prism::Orm::Model) do
      table_name :commenters
      has_many :comments, class_name: 'Comment', foreign_key: 'commenter_id'
      has_many :posts, through: :comments, source: :post
    end
    comment_class = Class.new(Prism::Orm::Model) do
      table_name :comments
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id'
      belongs_to :commenter, class_name: 'Commenter', foreign_key: 'commenter_id'
    end
    [post_class, commenter_class, comment_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Commenter, commenter_class)
    Object.const_set(:Comment, comment_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Commenter Comment].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_has_many_through_collects_source_records
    post = Post.create!(title: 'hello world')
    alice = Commenter.create!(name: 'alice')
    bob = Commenter.create!(name: 'bob')
    Comment.create!(post_id: post.id, commenter_id: alice.id, body: 'nice')
    Comment.create!(post_id: post.id, commenter_id: bob.id, body: 'agreed')

    names = post.commenters.map(&:name).sort
    assert_equal %w[alice bob], names
  end

  def test_has_many_through_dedupes_by_id
    post = Post.create!(title: 'hello world')
    alice = Commenter.create!(name: 'alice')
    Comment.create!(post_id: post.id, commenter_id: alice.id, body: 'first')
    Comment.create!(post_id: post.id, commenter_id: alice.id, body: 'second')

    assert_equal [alice.id], post.commenters.map(&:id)
  end

  def test_has_many_through_is_symmetric_from_the_other_side
    post = Post.create!(title: 'hello world')
    alice = Commenter.create!(name: 'alice')
    Comment.create!(post_id: post.id, commenter_id: alice.id, body: 'first')

    assert_equal [post.id], alice.posts.map(&:id)
  end

  def test_has_many_through_returns_empty_array_without_through_records
    post = Post.create!(title: 'lonely')
    assert_equal [], post.commenters
  end

  def test_has_many_through_default_source_is_singularized_name
    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id'
      has_many :commenters, through: :comments
    end
    post_class.store = @store
    post = post_class.create!(title: 'defaults')
    alice = Commenter.create!(name: 'alice')
    Comment.create!(post_id: post.id, commenter_id: alice.id, body: 'default source')

    assert_equal ['alice'], post_class.find(post.id).commenters.map(&:name)
  end

  def test_has_many_through_rejects_dependent_option
    error = assert_raises(ArgumentError) do
      Class.new(Prism::Orm::Model) do
        table_name :posts
        has_many :comments, class_name: 'Comment', foreign_key: 'post_id'
        has_many :commenters, through: :comments, source: :commenter, dependent: :destroy
      end
    end
    assert_match(/dependent/, error.message)
  end

  def test_includes_has_many_through_avoids_n_plus_one_queries
    3.times do |i|
      post = Post.create!(title: "post#{i}")
      2.times do |j|
        commenter = Commenter.create!(name: "commenter#{i}-#{j}")
        Comment.create!(post_id: post.id, commenter_id: commenter.id, body: 'hi')
      end
    end

    @store.reset_query_count!
    posts = Post.all.includes(:commenters).to_a
    baseline = @store.query_count

    total = posts.sum { |post| post.commenters.size }
    assert_equal baseline, @store.query_count,
      "expected preloaded #commenters to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal 6, total
  end

  def test_includes_has_many_through_unknown_through_raises
    broken_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      has_many :commenters, through: :nonexistent, source: :commenter
    end
    broken_class.store = @store
    broken_class.create!(title: 'x')
    assert_raises(ArgumentError) { broken_class.all.includes(:commenters).to_a }
  end
end

# Wraps Store#all/#find to count reads, mirroring test_orm_eager_loading.rb's
# CountingStore so this file has no load-order dependency on it.
class CountingThroughStore < Prism::Orm::Store
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
