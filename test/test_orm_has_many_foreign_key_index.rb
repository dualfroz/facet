require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmHasManyForeignKeyIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-fk-index-store')
    @store = CountingFkIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:parents, %w[id name])
    @store.create_table(:children, %w[id parent_id label])

    parent_class = Class.new(Facet::Orm::Model) do
      table_name :parents
      has_many :children, class_name: 'Child', foreign_key: 'parent_id'
    end
    child_class = Class.new(Facet::Orm::Model) { table_name :children }
    [parent_class, child_class].each { |klass| klass.store = @store }
    Object.const_set(:FkParent, parent_class)
    Object.const_set(:Child, child_class)

    @mom = FkParent.create!(name: 'mom')
    @dad = FkParent.create!(name: 'dad')
    Child.create!(parent_id: @mom.id, label: 'a')
    Child.create!(parent_id: @mom.id, label: 'b')
    Child.create!(parent_id: @dad.id, label: 'c')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[FkParent Child].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_has_many_reader_full_scans_without_an_index_on_the_foreign_key
    @store.reset_counts!
    labels = @mom.children.to_a.map { |child| child['label'] }.sort
    assert_equal %w[a b], labels
    assert_equal 1, @store.scan_count, 'without an index, Target.where(foreign_key => id) must fall back to a scan'
    assert_equal 0, @store.index_hits
  end

  def test_has_many_reader_never_scans_once_the_foreign_key_is_indexed
    @store.add_index(:children, :parent_id)

    @store.reset_counts!
    labels = @mom.children.to_a.map { |child| child['label'] }.sort
    assert_equal %w[a b], labels
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.index_hits

    @store.reset_counts!
    dad_labels = @dad.children.to_a.map { |child| child['label'] }
    assert_equal ['c'], dad_labels
    assert_equal 0, @store.scan_count
  end

  def test_indexed_foreign_key_reflects_writes_immediately
    @store.add_index(:children, :parent_id)
    Child.create!(parent_id: @mom.id, label: 'd')

    @store.reset_counts!
    labels = @mom.children.to_a.map { |child| child['label'] }.sort
    assert_equal %w[a b d], labels
    assert_equal 0, @store.scan_count
  end
end

class OrmHasManyPolymorphicForeignKeyIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-fk-poly-index-store')
    @store = CountingFkIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title])
    @store.create_table(:comments, %w[id body])
    @store.create_table(:tags, %w[id taggable_id taggable_type label])

    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      has_many :tags, class_name: 'Tag', as: :taggable
    end
    comment_class = Class.new(Facet::Orm::Model) do
      table_name :comments
      has_many :tags, class_name: 'Tag', as: :taggable
    end
    tag_class = Class.new(Facet::Orm::Model) { table_name :tags }
    [post_class, comment_class, tag_class].each { |klass| klass.store = @store }
    Object.const_set(:TaggablePost, post_class)
    Object.const_set(:TaggableComment, comment_class)
    Object.const_set(:Tag, tag_class)

    @post = TaggablePost.create!(title: 'hello')
    @comment = TaggableComment.create!(body: 'hi')
    Tag.create!(taggable_id: @post.id, taggable_type: 'TaggablePost', label: 'ruby')
    Tag.create!(taggable_id: @comment.id, taggable_type: 'TaggableComment', label: 'ruby')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[TaggablePost TaggableComment Tag].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_without_any_index_the_polymorphic_reader_falls_back_to_a_scan
    @store.reset_counts!
    labels = @post.tags.to_a.map { |tag| tag['label'] }
    assert_equal ['ruby'], labels
    assert_equal 1, @store.scan_count
  end

  def test_single_column_index_on_the_id_half_already_avoids_the_scan
    @store.add_index(:tags, :taggable_id)

    @store.reset_counts!
    labels = @post.tags.to_a.map { |tag| tag['label'] }
    assert_equal ['ruby'], labels
    assert_equal 0, @store.scan_count,
      'the index narrows candidates by id; the leftover type equality is filtered in memory, not by scanning'
  end

  def test_composite_index_over_both_columns_avoids_the_scan_and_stays_type_scoped
    @store.add_index(:tags, %i[taggable_id taggable_type])

    @store.reset_counts!
    post_labels = @post.tags.to_a.map { |tag| tag['label'] }
    assert_equal ['ruby'], post_labels
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.index_hits

    @store.reset_counts!
    comment_labels = @comment.tags.to_a.map { |tag| tag['label'] }
    assert_equal ['ruby'], comment_labels
    assert_equal 0, @store.scan_count
  end
end

class CountingFkIndexStore < Facet::Orm::Store
  attr_reader :scan_count, :index_hits

  def initialize(*args)
    super
    @scan_count = 0
    @index_hits = 0
  end

  def all(table)
    @scan_count += 1
    super
  end

  def lookup_by_index(table, equalities)
    result = super
    @index_hits += 1 unless result.nil?
    result
  end

  def reset_counts!
    @scan_count = 0
    @index_hits = 0
  end
end
