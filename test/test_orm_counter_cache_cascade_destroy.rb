require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class OrmCounterCacheCascadeDestroyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-counter-cache-cascade-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title comments_count likes_count deleted_at])
    @store.create_table(:comments, %w[id post_id body likes_count deleted_at])
    @store.create_table(:likes, %w[id likeable_id likeable_type deleted_at])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :comments, foreign_key: 'post_id', dependent: :destroy
      has_many :likes, as: :likeable, dependent: :destroy
      acts_as_paranoid
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id', counter_cache: true
      has_many :likes, as: :likeable, dependent: :destroy
      acts_as_paranoid
    end
    like_class = Class.new(Facet::Orm::Model) do
      table_name :likes
      belongs_to :likeable, polymorphic: true, counter_cache: true
      acts_as_paranoid
    end
    [post_class, comment_class, like_class].each { |k| k.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Comment, comment_class)
    Object.const_set(:Like, like_class)

    @post = Post.create!(title: 'hi')
    @comment = Comment.create!(post_id: @post.id, body: 'yo')
    @like_on_post = Like.create!(likeable_id: @post.id, likeable_type: 'Post')
    @like_on_comment = Like.create!(likeable_id: @comment.id, likeable_type: 'Comment')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Comment Like].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_counters_start_correct
    assert_equal 1, @post.reload.comments_count
    assert_equal 1, @post.reload.likes_count
    assert_equal 1, @comment.reload.likes_count
  end

  def test_cascading_soft_destroy_does_not_clobber_a_counter_bumped_by_its_own_nested_cascade
    @post.destroy

    assert_equal 0, @store.find(:comments, @comment.id)['likes_count']
    assert_equal 0, @store.find(:posts, @post.id)['comments_count']
    assert_equal 0, @store.find(:posts, @post.id)['likes_count']
  end

  def test_recursive_restore_brings_every_counter_back_exactly_once
    @post.destroy
    @post.restore(recursive: true)

    assert_equal 1, @post.reload.comments_count
    assert_equal 1, @post.reload.likes_count
    assert_equal 1, Comment.find(@comment.id).likes_count
  end
end
