require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmBelongsToTouchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-belongs-to-touch-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title updated_at reviewed_at])
    @store.create_table(:comments, %w[id body post_id updated_at])
    @store.create_table(:notes, %w[id body post_id updated_at])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id'
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id', touch: true
    end
    note_class = Class.new(Facet::Orm::Model) do
      table_name :notes
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id', touch: :reviewed_at
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

  def test_creating_a_child_touches_the_owner
    post = Post.create!(title: 'hello')
    original = post.updated_at
    sleep 0.01

    Comment.create!(body: 'first', post_id: post.id)

    assert post.reload.updated_at > original
  end

  def test_updating_a_child_touches_the_owner_even_without_changing_the_foreign_key
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'first', post_id: post.id)
    original = post.reload.updated_at
    sleep 0.01

    comment.update!(body: 'first, edited')

    assert post.reload.updated_at > original
  end

  def test_destroying_a_child_touches_the_owner
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'first', post_id: post.id)
    original = post.reload.updated_at
    sleep 0.01

    comment.destroy

    assert post.reload.updated_at > original
  end

  def test_reassigning_the_owner_touches_both_old_and_new_owner
    post_a = Post.create!(title: 'a')
    post_b = Post.create!(title: 'b')
    comment = Comment.create!(body: 'wandering', post_id: post_a.id)
    original_a = post_a.reload.updated_at
    original_b = post_b.reload.updated_at
    sleep 0.01

    comment.update!(post_id: post_b.id)

    assert post_a.reload.updated_at > original_a
    assert post_b.reload.updated_at > original_b
  end

  def test_touch_with_a_symbol_column_touches_that_column_on_the_owner
    post = Post.create!(title: 'hello')
    refute post.reviewed_at

    Note.create!(body: 'looks good', post_id: post.id)

    assert post.reload.reviewed_at
  end

  def test_creating_a_child_without_an_owner_does_not_raise
    Comment.create!(body: 'orphan', post_id: nil)
  end

  def test_touching_an_already_destroyed_owner_does_not_raise
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'first', post_id: post.id)
    post.destroy

    comment.update!(body: 'edited after owner is gone')
  end

  def test_destroying_a_locked_paranoid_owner_with_cascaded_touching_children_does_not_raise
    @store.create_table(:locked_posts, %w[id title deleted_at lock_version])
    @store.create_table(:locked_comments, %w[id body locked_post_id deleted_at])

    locked_post_class = Class.new(Facet::Orm::Model) do
      table_name :locked_posts
      acts_as_paranoid
      has_many :comments, class_name: 'LockedComment', foreign_key: 'locked_post_id', dependent: :destroy
    end
    locked_comment_class = Class.new(Facet::Orm::Model) do
      table_name :locked_comments
      acts_as_paranoid
      belongs_to :post, class_name: 'LockedPost', foreign_key: 'locked_post_id', touch: true
    end
    [locked_post_class, locked_comment_class].each { |klass| klass.store = @store }
    Object.const_set(:LockedPost, locked_post_class)
    Object.const_set(:LockedComment, locked_comment_class)

    post = LockedPost.create!(title: 'hello')
    3.times { |n| LockedComment.create!(body: "comment #{n}", locked_post_id: post.id) }

    post.destroy

    assert post.destroyed?
    assert_nil LockedPost.find_by(id: post.id)
  ensure
    %i[LockedPost LockedComment].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end
end
