require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmUniquenessScopeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-uniqueness-scope-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:likes, %w[id likeable_id likeable_type user_id])

    like_class = Class.new(Facet::Orm::Model) do
      table_name :likes
      validates :user_id, presence: true, uniqueness: { scope: %i[likeable_id likeable_type] }
    end
    like_class.store = @store
    Object.const_set(:Like, like_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Like) if Object.const_defined?(:Like)
  end

  def test_rejects_a_second_like_from_the_same_user_on_the_same_target
    Like.create!(user_id: 1, likeable_id: 5, likeable_type: 'Post')
    duplicate = Like.new(user_id: 1, likeable_id: 5, likeable_type: 'Post')

    refute duplicate.valid?
    assert_includes duplicate.errors[:user_id], 'must be unique'
  end

  def test_allows_the_same_user_to_like_a_different_target
    Like.create!(user_id: 1, likeable_id: 5, likeable_type: 'Post')
    other_target = Like.new(user_id: 1, likeable_id: 6, likeable_type: 'Post')

    assert other_target.valid?
  end

  def test_allows_the_same_user_to_like_the_same_id_on_a_different_type
    Like.create!(user_id: 1, likeable_id: 5, likeable_type: 'Post')
    other_type = Like.new(user_id: 1, likeable_id: 5, likeable_type: 'Photo')

    assert other_type.valid?
  end

  def test_allows_a_different_user_to_like_the_same_target
    Like.create!(user_id: 1, likeable_id: 5, likeable_type: 'Post')
    other_user = Like.new(user_id: 2, likeable_id: 5, likeable_type: 'Post')

    assert other_user.valid?
  end

  def test_saving_the_same_record_twice_is_not_a_conflict_with_itself
    like = Like.create!(user_id: 1, likeable_id: 5, likeable_type: 'Post')
    like.user_id = 1

    assert like.valid?
  end

  def test_unscoped_uniqueness_still_works_without_a_scope_option
    scoreless_store = Facet::Orm::Store.new(File.join(@dir, 'scoreless.pstore'))
    scoreless_store.create_table(:tags, %w[id name])
    tag_class = Class.new(Facet::Orm::Model) do
      table_name :tags
      validates :name, presence: true, uniqueness: true
    end
    tag_class.store = scoreless_store
    tag_class.create!(name: 'ruby')

    duplicate = tag_class.new(name: 'ruby')
    refute duplicate.valid?
  end
end
