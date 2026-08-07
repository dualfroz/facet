require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmNestedAttributesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-nested-attrs-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
    @store.create_table(:comments, %w[id body post_id])
    @store.create_table(:accounts, %w[id owner_id plan])
    @store.create_table(:users, %w[id name])

    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id', dependent: :destroy
      accepts_nested_attributes_for :comments, allow_destroy: true, reject_if: :all_blank, limit: 3
    end
    comment_class = Class.new(Prism::Orm::Model) do
      table_name :comments
      belongs_to :post, class_name: 'Post', foreign_key: 'post_id'
      validates :body, presence: true, length: { minimum: 2 }
    end
    user_class = Class.new(Prism::Orm::Model) do
      table_name :users
      has_one :account, class_name: 'Account', foreign_key: 'owner_id'
      accepts_nested_attributes_for :account
    end
    account_class = Class.new(Prism::Orm::Model) do
      table_name :accounts
      belongs_to :owner, class_name: 'User', foreign_key: 'owner_id'
      validates :plan, presence: true
    end

    [post_class, comment_class, user_class, account_class].each { |klass| klass.store = @store }
    Object.const_set(:Post, post_class)
    Object.const_set(:Comment, comment_class)
    Object.const_set(:User, user_class)
    Object.const_set(:Account, account_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Post Comment User Account].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_builds_and_saves_new_children_of_a_new_parent
    post = Post.create!(
      title: 'hello',
      comments_attributes: [{ body: 'first' }, { body: 'second' }]
    )

    assert_equal 2, Comment.where(post_id: post.id).count
    bodies = Comment.where(post_id: post.id).map(&:body).sort
    assert_equal %w[first second], bodies
  end

  def test_accepts_indexed_hash_form_like_a_rails_form_builder
    post = Post.create!(
      title: 'hello',
      comments_attributes: { '0' => { body: 'first' }, '1' => { body: 'second' } }
    )

    assert_equal 2, Comment.where(post_id: post.id).count
  end

  def test_updates_an_existing_child_by_id
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'original', post_id: post.id)

    post.update!(comments_attributes: [{ id: comment.id, body: 'edited' }])

    assert_equal 'edited', comment.reload.body
  end

  def test_allow_destroy_removes_the_child
    post = Post.create!(title: 'hello')
    comment = Comment.create!(body: 'doomed', post_id: post.id)

    post.update!(comments_attributes: [{ id: comment.id, _destroy: '1' }])

    assert_nil Comment.store.find(Comment.table_name, comment.id)
  end

  def test_destroy_flag_is_ignored_without_allow_destroy
    no_destroy_post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      has_many :comments, class_name: 'Comment', foreign_key: 'post_id'
      accepts_nested_attributes_for :comments
    end
    no_destroy_post_class.store = @store
    post = no_destroy_post_class.create!(title: 'hello')
    comment = Comment.create!(body: 'kept', post_id: post.id)

    post.update!(comments_attributes: [{ id: comment.id, _destroy: '1', body: 'still here' }])

    refute_nil Comment.store.find(Comment.table_name, comment.id)
    assert_equal 'still here', comment.reload.body
  end

  def test_reject_if_all_blank_skips_empty_new_records
    post = Post.create!(title: 'hello', comments_attributes: [{ body: '' }, { body: 'real' }])

    assert_equal 1, Comment.where(post_id: post.id).count
    assert_equal 'real', Comment.where(post_id: post.id).first.body
  end

  def test_limit_raises_when_exceeded
    assert_raises(Prism::Orm::NestedAttributes::TooManyRecords) do
      Post.create!(title: 'hello', comments_attributes: [{ body: 'a' }, { body: 'b' }, { body: 'c' }, { body: 'd' }])
    end
  end

  def test_invalid_nested_record_blocks_the_whole_save_and_reports_errors
    post = Post.new(title: 'hello', comments_attributes: [{ body: 'good enough' }, { body: 'x' }])

    refute post.save
    assert post.new_record?
    assert post.errors.key?(:comments)
    assert_equal 0, Comment.count
  end

  def test_id_pointing_at_another_parents_child_is_rejected_not_hijacked
    post_a = Post.create!(title: 'a')
    post_b = Post.create!(title: 'b')
    foreign_comment = Comment.create!(body: 'belongs to a', post_id: post_a.id)

    refute post_b.update(comments_attributes: [{ id: foreign_comment.id, body: 'hijacked' }])
    assert_equal 'belongs to a', foreign_comment.reload.body
    assert_equal post_a.id, foreign_comment.reload.post_id
  end

  def test_id_on_a_brand_new_parent_is_rejected
    post = Post.new(title: 'hello', comments_attributes: [{ id: 999, body: 'ghost' }])

    refute post.save
    assert post.errors.key?(:comments)
  end

  def test_has_one_nested_attributes_builds_the_single_record
    user = User.create!(name: 'ada', account_attributes: { plan: 'pro' })

    account = Account.find_by(owner_id: user.id)
    refute_nil account
    assert_equal 'pro', account.plan
  end

  def test_has_one_nested_attributes_updates_the_existing_record
    user = User.create!(name: 'ada')
    account = Account.create!(plan: 'free', owner_id: user.id)

    user.update!(account_attributes: { id: account.id, plan: 'pro' })

    assert_equal 'pro', account.reload.plan
  end

  def test_does_not_support_associations_other_than_has_many_or_has_one
    assert_raises(ArgumentError) do
      Class.new(Prism::Orm::Model) do
        table_name :comments
        belongs_to :post, class_name: 'Post', foreign_key: 'post_id'
        accepts_nested_attributes_for :post
      end
    end
  end
end
