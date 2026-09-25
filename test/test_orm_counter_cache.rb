require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmCounterCacheTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-counter-cache-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title comments_count annotations])
    @store.create_table(:comments, %w[id body post_id deleted_at])
    @store.create_table(:notes, %w[id body post_id])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id'
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      acts_as_paranoid
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id', counter_cache: true
    end
    note_class = Class.new(Facet::Orm::Model) do
      table_name :notes
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id', counter_cache: :annotations
    end
    [post_class, comment_class, note_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Comment, comment_class)
    Object.const_set(:Note, note_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Comment Note].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_create_increments_default_column
    post = Post.create!(title: 'hello', comments_count: 0)
    Comment.create!(body: 'first', post_id: post.id)
    Comment.create!(body: 'second', post_id: post.id)

    assert_equal 2, post.reload.comments_count
  end

  def test_destroy_decrements_default_column
    post = Post.create!(title: 'hello', comments_count: 0)
    c1 = Comment.create!(body: 'first', post_id: post.id)
    Comment.create!(body: 'second', post_id: post.id)

    c1.destroy

    assert_equal 1, post.reload.comments_count
  end

  def test_reassigning_the_owner_moves_the_count
    post_a = Post.create!(title: 'a', comments_count: 0)
    post_b = Post.create!(title: 'b', comments_count: 0)
    comment = Comment.create!(body: 'wandering', post_id: post_a.id)

    comment.update!(post_id: post_b.id)

    assert_equal 0, post_a.reload.comments_count
    assert_equal 1, post_b.reload.comments_count
  end

  def test_clearing_the_owner_decrements_without_incrementing_anything
    post = Post.create!(title: 'a', comments_count: 0)
    comment = Comment.create!(body: 'orphanable', post_id: post.id)

    comment.update!(post_id: nil)

    assert_equal 0, post.reload.comments_count
  end

  def test_custom_column_name_is_used_when_given_a_symbol
    post = Post.create!(title: 'hello', comments_count: 0, annotations: 0)
    Note.create!(body: 'note one', post_id: post.id)

    assert_equal 1, post.reload.annotations
    assert_equal 0, post.comments_count
  end

  def test_creating_without_an_owner_does_not_touch_any_counter
    Comment.create!(body: 'orphan', post_id: nil)
  end

  def test_unrelated_update_does_not_double_count
    post = Post.create!(title: 'hello', comments_count: 0)
    comment = Comment.create!(body: 'first', post_id: post.id)

    comment.update!(body: 'first, edited')

    assert_equal 1, post.reload.comments_count
  end

  def test_destroying_every_child_through_the_association_zeroes_the_counter
    post = Post.create!(title: 'hello', comments_count: 0)
    Comment.create!(body: 'first', post_id: post.id)
    Comment.create!(body: 'second', post_id: post.id)

    post.comments.each(&:destroy)

    assert_equal 0, post.reload.comments_count
  end

  def test_restoring_a_soft_deleted_child_reincrements_the_counter
    post = Post.create!(title: 'hello', comments_count: 0)
    comment = Comment.create!(body: 'first', post_id: post.id)
    comment.destroy
    assert_equal 0, post.reload.comments_count

    comment.restore

    assert_equal 1, post.reload.comments_count
  end
end
