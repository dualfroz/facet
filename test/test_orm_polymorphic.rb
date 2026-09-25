require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmPolymorphicTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-polymorphic-store')
    @store = CountingPolymorphicStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
    @store.create_table(:photos, %w[id caption])
    @store.create_table(:likes, %w[id likeable_id likeable_type user_id])
    @store.create_table(:previews, %w[id previewable_id previewable_type url])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :likes, class_name: 'Like', as: :likeable, dependent: :destroy
      has_one :preview, class_name: 'Preview', as: :previewable, dependent: :nullify
    end
    photo_class = Class.new(Facet::Orm::Model) do
      table_name :photos
      has_many :likes, class_name: 'Like', as: :likeable, dependent: :destroy
    end
    like_class = Class.new(Facet::Orm::Model) do
      table_name :likes
      belongs_to :likeable, polymorphic: true
    end
    preview_class = Class.new(Facet::Orm::Model) do
      table_name :previews
      belongs_to :previewable, polymorphic: true
    end
    [post_class, photo_class, like_class, preview_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Photo, photo_class)
    Object.const_set(:Like, like_class)
    Object.const_set(:Preview, preview_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Photo Like Preview].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_polymorphic_belongs_to_resolves_the_right_class
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    like_on_post = Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)
    like_on_photo = Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 1)

    assert_instance_of Post, like_on_post.likeable
    assert_equal post.id, like_on_post.likeable.id
    assert_instance_of Photo, like_on_photo.likeable
    assert_equal photo.id, like_on_photo.likeable.id
  end

  def test_polymorphic_belongs_to_setter_stamps_both_columns
    post = Post.create!(title: 'hello')
    like = Like.new(user_id: 1)
    like.likeable = post
    like.save!

    assert_equal post.id, like.likeable_id
    assert_equal 'Post', like.likeable_type
  end

  def test_polymorphic_belongs_to_returns_nil_without_a_target
    like = Like.create!(user_id: 1)
    assert_nil like.likeable
  end

  def test_polymorphic_has_many_scopes_by_type_not_just_id
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)
    Like.create!(likeable_id: post.id, likeable_type: 'Photo', user_id: 2)

    assert_equal 1, post.likes.count
    assert_equal 1, post.likes.first.user_id
  end

  def test_polymorphic_has_many_dependent_destroy_only_removes_own_type
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)
    Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 1)

    post.destroy

    assert_equal 1, Like.all.count
    assert_equal 'Photo', Like.all.first.likeable_type
  end

  def test_polymorphic_has_one_dependent_nullify_clears_both_columns
    post = Post.create!(title: 'hello')
    preview = Preview.create!(previewable_id: post.id, previewable_type: 'Post', url: '/p.png')

    post.destroy

    reloaded = Preview.find(preview.id)
    assert_nil reloaded.previewable_id
    assert_nil reloaded.previewable_type
  end

  def test_polymorphic_has_one_setter_stamps_both_columns
    post = Post.create!(title: 'hello')
    preview = Preview.create!(url: '/p.png')
    post.preview = preview

    reloaded = Preview.find(preview.id)
    assert_equal post.id, reloaded.previewable_id
    assert_equal 'Post', reloaded.previewable_type
  end

  def test_includes_polymorphic_belongs_to_batches_across_mixed_types
    post = Post.create!(title: 'hello')
    photo = Photo.create!(caption: 'sunset')
    Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 1)
    Like.create!(likeable_id: photo.id, likeable_type: 'Photo', user_id: 2)
    Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: 3)

    @store.reset_query_count!
    likes = Like.all.includes(:likeable).to_a
    baseline = @store.query_count

    targets = likes.map { |like| like.likeable.class.name }.sort
    assert_equal baseline, @store.query_count,
      "expected preloaded #likeable to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal %w[Photo Post Post], targets
  end

  def test_includes_polymorphic_has_many_avoids_n_plus_one_queries
    3.times do |i|
      post = Post.create!(title: "post#{i}")
      2.times { |j| Like.create!(likeable_id: post.id, likeable_type: 'Post', user_id: j) }
    end
    Photo.create!(caption: 'unrelated')

    @store.reset_query_count!
    posts = Post.all.includes(:likes).to_a
    baseline = @store.query_count

    total = posts.sum { |post| post.likes.size }
    assert_equal baseline, @store.query_count,
      "expected preloaded #likes to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal 6, total
  end
end

class CountingPolymorphicStore < Facet::Orm::Store
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
