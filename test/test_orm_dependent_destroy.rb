require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmDependentDestroyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-dependent-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])
    @store.create_table(:profiles, %w[id author_id bio])

    author_class = Class.new(Facet::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id', dependent: :destroy
      has_one :profile, class_name: 'Profile', foreign_key: 'author_id', dependent: :nullify
    end
    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    profile_class = Class.new(Facet::Orm::Model) do
      table_name :profiles
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    [author_class, post_class, profile_class].each { |klass| klass.store = @store }
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
    Object.const_set(:Profile, profile_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Author Post Profile].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_dependent_destroy_removes_has_many_children
    author = Author.create!(name: 'alice')
    p1 = Post.create!(title: 'a', author_id: author.id)
    p2 = Post.create!(title: 'b', author_id: author.id)

    author.destroy

    assert_raises(Facet::Orm::RecordNotFound) { Post.find(p1.id) }
    assert_raises(Facet::Orm::RecordNotFound) { Post.find(p2.id) }
  end

  def test_dependent_nullify_clears_foreign_key_on_has_one
    author = Author.create!(name: 'alice')
    profile = Profile.create!(bio: 'hello', author_id: author.id)

    author.destroy

    reloaded = Profile.find(profile.id)
    assert_nil reloaded.author_id
  end

  def test_destroying_childless_author_does_not_raise
    author = Author.create!(name: 'lonely')
    assert author.destroy.destroyed?
  end

  def test_unsupported_dependent_option_raises_at_declaration_time
    assert_raises(ArgumentError) do
      Class.new(Facet::Orm::Model) do
        table_name :posts
        has_many :whatever, class_name: 'Post', foreign_key: 'author_id', dependent: :delete_all
      end
    end
  end
end
