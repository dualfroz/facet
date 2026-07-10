require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmEagerLoadingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-eager-store')
    @store = CountingStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])
    @store.create_table(:bios, %w[id author_id headline])

    author_class = Class.new(Prism::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id'
      has_one :bio, class_name: 'Bio', foreign_key: 'author_id'
    end
    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    bio_class = Class.new(Prism::Orm::Model) do
      table_name :bios
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    [author_class, post_class, bio_class].each { |klass| klass.store = @store }
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
    Object.const_set(:Bio, bio_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Author Post Bio].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_includes_has_many_avoids_n_plus_one_queries
    3.times do |i|
      author = Author.create!(name: "author#{i}")
      2.times { |j| Post.create!(title: "post#{i}-#{j}", author_id: author.id) }
    end

    @store.reset_query_count!
    authors = Author.all.includes(:posts).to_a
    baseline_queries = @store.query_count

    authors.each { |author| author.posts.each(&:title) }
    assert_equal baseline_queries, @store.query_count,
      "expected preloaded #posts to be free, but it issued #{@store.query_count - baseline_queries} more queries"

    total_posts = authors.sum { |author| author.posts.size }
    assert_equal 6, total_posts
  end

  def test_includes_belongs_to_preloads_single_target
    author = Author.create!(name: 'solo')
    Post.create!(title: 'a', author_id: author.id)
    Post.create!(title: 'b', author_id: author.id)

    @store.reset_query_count!
    posts = Post.all.includes(:author).to_a
    baseline = @store.query_count
    names = posts.map { |post| post.author.name }

    assert_equal baseline, @store.query_count
    assert_equal %w[solo solo], names
  end

  def test_includes_has_one_preloads
    author = Author.create!(name: 'writer')
    Bio.create!(headline: 'hello there', author_id: author.id)

    loaded = Author.all.includes(:bio).to_a.first
    assert_equal 'hello there', loaded.bio.headline
  end

  def test_includes_unknown_association_raises
    Author.create!(name: 'x')
    assert_raises(ArgumentError) { Author.all.includes(:nope).to_a }
  end

  def test_includes_reduces_queries_compared_to_lazy_access
    3.times do |i|
      author = Author.create!(name: "author#{i}")
      2.times { |j| Post.create!(title: "post#{i}-#{j}", author_id: author.id) }
    end

    @store.reset_query_count!
    Author.all.to_a.each { |author| author.posts.to_a }
    lazy_queries = @store.query_count

    @store.reset_query_count!
    Author.all.includes(:posts).to_a.each { |author| author.posts.to_a }
    eager_queries = @store.query_count

    assert_equal 4, lazy_queries # 1 authors query + 1 posts query per author (N+1)
    assert_equal 2, eager_queries # 1 authors query + 1 batched posts query
    assert_operator eager_queries, :<, lazy_queries
  end
end

# Wraps Store#all/#find to count reads, so tests can assert on actual
# query volume instead of trusting behavior "looks" batched.
class CountingStore < Prism::Orm::Store
  def initialize(*)
    super
    @query_count = 0
  end

  def query_count
    @query_count
  end

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
