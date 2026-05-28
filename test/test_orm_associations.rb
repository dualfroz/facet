require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmAssociationsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-assoc-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])

    author_class = Class.new(Prism::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id'
    end
    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    author_class.store = @store
    post_class.store = @store
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Author Post].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_belongs_to_returns_associated_record
    author = Author.create!(name: 'foksiu')
    post = Post.create!(title: 'hello', author_id: author.id)
    assert_equal author, post.author
  end

  def test_belongs_to_setter_updates_foreign_key
    author = Author.create!(name: 'foksiu')
    post = Post.create!(title: 'hello')
    post.author = author
    assert_equal author.id, post.author_id
  end

  def test_belongs_to_returns_nil_when_unset
    post = Post.create!(title: 'orphan')
    assert_nil post.author
  end

  def test_has_many_returns_associated_records
    author = Author.create!(name: 'foksiu')
    Post.create!(title: 'first', author_id: author.id)
    Post.create!(title: 'second', author_id: author.id)
    Post.create!(title: 'not mine', author_id: nil)

    titles = author.posts.map(&:title).sort
    assert_equal %w[first second], titles
  end

  def test_where_with_array_condition
    a = Author.create!(name: 'a')
    b = Author.create!(name: 'b')
    Author.create!(name: 'c')
    matched = Author.where(id: [a.id, b.id]).map(&:name).sort
    assert_equal %w[a b], matched
  end

  def test_order_and_limit
    Author.create!(name: 'charlie')
    Author.create!(name: 'alice')
    Author.create!(name: 'bob')
    names = Author.order(:name).limit(2).map(&:name)
    assert_equal %w[alice bob], names
  end

  def test_order_desc
    Author.create!(name: 'alice')
    Author.create!(name: 'bob')
    names = Author.order(:name, :desc).map(&:name)
    assert_equal %w[bob alice], names
  end

  def test_find_by
    Author.create!(name: 'findme')
    found = Author.find_by(name: 'findme')
    refute_nil found
    assert_nil Author.find_by(name: 'nope')
  end

  def test_pluck
    Author.create!(name: 'a')
    Author.create!(name: 'b')
    assert_equal %w[a b], Author.all.pluck(:name)
  end
end
