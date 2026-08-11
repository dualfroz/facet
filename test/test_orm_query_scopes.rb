require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmQueryScopesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-query-scopes')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:articles, %w[id title published views])
    @article_class = Class.new(Prism::Orm::Model) do
      table_name :articles
      scope :published, -> { where(published: true) }
      scope :popular, ->(threshold) { where(views: { gte: threshold }) }
    end
    Object.const_set(:Article, @article_class)
    Article.store = @store

    Article.create!(title: 'a', published: true, views: 100)
    Article.create!(title: 'b', published: false, views: 500)
    Article.create!(title: 'c', published: true, views: 5)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Article) if Object.const_defined?(:Article)
  end

  def test_scope_without_arguments
    titles = Article.published.order(:title).pluck(:title)
    assert_equal %w[a c], titles
  end

  def test_scope_with_argument
    titles = Article.popular(50).order(:title).pluck(:title)
    assert_equal %w[a b], titles
  end

  def test_scopes_are_chainable_with_relation_methods
    titles = Article.published.popular(10).pluck(:title)
    assert_equal ['a'], titles
  end

  def test_scopes_return_relation_not_array
    assert_kind_of Prism::Orm::Relation, Article.published
  end

  def test_default_scope_applies_to_all_and_where
    Object.send(:remove_const, :Article)
    scoped_class = Class.new(Prism::Orm::Model) do
      table_name :articles
      default_scope { where(published: true) }
    end
    Object.const_set(:Article, scoped_class)
    Article.store = @store

    assert_equal %w[a c], Article.all.order(:title).pluck(:title)
    assert_equal 2, Article.count
    assert_equal %w[a], Article.where(title: 'a').pluck(:title)
  end

  def test_unscoped_bypasses_default_scope
    Object.send(:remove_const, :Article)
    scoped_class = Class.new(Prism::Orm::Model) do
      table_name :articles
      default_scope { where(published: true) }
    end
    Object.const_set(:Article, scoped_class)
    Article.store = @store

    assert_equal 3, Article.unscoped.count
  end
end
