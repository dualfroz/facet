require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmPolymorphicCounterCacheTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-polymorphic-counter-cache-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title likes_count])
    @store.create_table(:photos, %w[id caption likes_count])
    @store.create_table(:likes, %w[id likeable_id likeable_type user_id deleted_at])
    @store.create_table(:reactions, %w[id reactable_id reactable_type score])
    @store.create_table(:posts_with_tally, %w[id title reactions_tally])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
    end
    photo_class = Class.new(Facet::Orm::Model) do
      table_name :photos
    end
    like_class = Class.new(Facet::Orm::Model) do
      table_name :likes
      acts_as_paranoid
      belongs_to :likeable, polymorphic: true, counter_cache: true
    end
    tally_post_class = Class.new(Facet::Orm::Model) do
      table_name :posts_with_tally
    end
    reaction_class = Class.new(Facet::Orm::Model) do
      table_name :reactions
      belongs_to :reactable, polymorphic: true, counter_cache: :reactions_tally
    end
    [post_class, photo_class, like_class, tally_post_class, reaction_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Photo, photo_class)
    Object.const_set(:Like, like_class)
    Object.const_set(:PostWithTally, tally_post_class)
    Object.const_set(:Reaction, reaction_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Photo Like PostWithTally Reaction].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end

  def test_create_increments_the_default_column_on_the_right_owner_type
    post = Post.create!(title: 'hello', likes_count: 0)
    photo = Photo.create!(caption: 'sunset', likes_count: 0)

    Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)
    Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 1)
    Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 2)

    assert_equal 1, post.reload.likes_count
    assert_equal 2, photo.reload.likes_count
  end

  def test_destroy_decrements_the_owner_of_the_recorded_type
    post = Post.create!(title: 'hello', likes_count: 0)
    like = Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)

    like.destroy

    assert_equal 0, post.reload.likes_count
  end

  def test_restoring_a_soft_deleted_like_reincrements_the_original_owner_type
    photo = Photo.create!(caption: 'sunset', likes_count: 0)
    like = Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 1)
    like.destroy
    assert_equal 0, photo.reload.likes_count

    like.restore

    assert_equal 1, photo.reload.likes_count
  end

  def test_reassigning_across_owner_types_moves_the_count_from_one_table_to_the_other
    post = Post.create!(title: 'hello', likes_count: 0)
    photo = Photo.create!(caption: 'sunset', likes_count: 0)
    like = Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)

    like.likeable = photo
    like.save!

    assert_equal 0, post.reload.likes_count
    assert_equal 1, photo.reload.likes_count
  end

  def test_reassigning_within_the_same_owner_type_moves_the_count
    post_a = Post.create!(title: 'a', likes_count: 0)
    post_b = Post.create!(title: 'b', likes_count: 0)
    like = Like.create!(likeable_id: post_a.id, likeable_type: 'Post', user_id: 1)

    like.update!(likeable_id: post_b.id)

    assert_equal 0, post_a.reload.likes_count
    assert_equal 1, post_b.reload.likes_count
  end

  def test_creating_without_an_owner_does_not_raise_or_touch_anything
    Like.create!(likeable_id: nil, likeable_type: nil, user_id: 1)
  end

  def test_custom_column_name_is_used_when_given_a_symbol
    post = PostWithTally.create!(title: 'hello', reactions_tally: 0)
    Reaction.create!(reactable_id: post.id, reactable_type: 'PostWithTally', score: 5)

    assert_equal 1, post.reload.reactions_tally
  end
end
