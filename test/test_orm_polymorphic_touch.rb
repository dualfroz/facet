require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmPolymorphicTouchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-polymorphic-touch-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title updated_at])
    @store.create_table(:photos, %w[id caption updated_at reviewed_at])
    @store.create_table(:comments, %w[id body commentable_id commentable_type updated_at])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', as: :commentable, dependent: :destroy
    end
    photo_class = Class.new(Facet::Orm::Model) do
      table_name :photos
      has_many :comments, class_name: 'Comment', as: :commentable, dependent: :destroy
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      belongs_to :commentable, polymorphic: true, touch: true
    end
    [post_class, photo_class, comment_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Photo, photo_class)
    Object.const_set(:Comment, comment_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Photo Comment].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_creating_a_child_touches_the_polymorphic_owner
    post = Post.create!(title: 'hello')
    original = post.updated_at
    sleep 0.01

    Comment.create!(body: 'first', commentable_id: post.id, commentable_type: 'Post')

    assert post.reload.updated_at > original
  end

  def test_touches_the_correct_owner_type_when_two_types_share_ids
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    original_post = post.reload.updated_at
    original_photo = photo.reload.updated_at
    sleep 0.01

    Comment.create!(body: 'on the photo', commentable_id: photo.id, commentable_type: 'Photo')

    assert_equal original_post, post.reload.updated_at
    assert photo.reload.updated_at > original_photo
  end

  def test_updating_a_child_touches_the_owner_even_without_changing_the_association
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'first', commentable_id: post.id, commentable_type: 'Post')
    original = post.reload.updated_at
    sleep 0.01

    comment.update!(body: 'first, edited')

    assert post.reload.updated_at > original
  end

  def test_destroying_a_child_touches_the_owner
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'first', commentable_id: post.id, commentable_type: 'Post')
    original = post.reload.updated_at
    sleep 0.01

    comment.destroy

    assert post.reload.updated_at > original
  end

  def test_reassigning_across_owner_types_touches_both_the_old_and_new_owner
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    comment = Comment.create!(body: 'wandering', commentable_id: post.id, commentable_type: 'Post')
    original_post = post.reload.updated_at
    original_photo = photo.reload.updated_at
    sleep 0.01

    comment.commentable = photo
    comment.save!

    assert post.reload.updated_at > original_post
    assert photo.reload.updated_at > original_photo
  end

  def test_destroying_the_owner_via_dependent_destroy_cascade_does_not_re_raise
    post = Post.create!(title: 'hello')
    Comment.create!(body: 'first', commentable_id: post.id, commentable_type: 'Post')
    Comment.create!(body: 'second', commentable_id: post.id, commentable_type: 'Post')

    post.destroy

    assert post.destroyed?
    assert_nil Post.find_by(id: post.id)
  end

  def test_creating_a_child_without_an_owner_does_not_raise
    Comment.create!(body: 'orphan', commentable_id: nil, commentable_type: nil)
  end
end
