require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmEnumTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-enum-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:posts, %w[id title status role])
    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      enum :status, { draft: 0, published: 1, archived: 2 }
      enum role: { author: 0, editor: 1 }, prefix: true
    end
    post_class.store = @store
    Object.const_set(:EnumPost, post_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :EnumPost) if Object.const_defined?(:EnumPost)
  end

  def test_reader_translates_raw_value_to_label
    post = EnumPost.create!(title: 'a', status: :published)
    assert_equal 'published', post.status
    assert_equal 1, post['status']
  end

  def test_writer_accepts_symbol_string_or_raw_value
    post = EnumPost.new(title: 'a')
    post.status = :draft
    assert_equal 0, post['status']
    post.status = 'published'
    assert_equal 1, post['status']
    post.status = 2
    assert_equal 'archived', post.status
  end

  def test_invalid_value_raises_argument_error_immediately
    post = EnumPost.new(title: 'a')
    assert_raises(ArgumentError) { post.status = :deleted }
  end

  def test_nil_clears_the_attribute
    post = EnumPost.new(title: 'a', status: :draft)
    post.status = nil
    assert_nil post.status
    assert_nil post['status']
  end

  def test_predicate_methods
    post = EnumPost.new(title: 'a', status: :draft)
    assert post.draft?
    refute post.published?
    post.status = :published
    assert post.published?
    refute post.draft?
  end

  def test_bang_method_sets_and_persists
    post = EnumPost.create!(title: 'a', status: :draft)
    post.published!
    assert_equal 'published', post.status
    assert_equal 'published', EnumPost.find(post.id).status
  end

  def test_class_scope_matches_generated_predicate
    EnumPost.create!(title: 'draft one', status: :draft)
    EnumPost.create!(title: 'published one', status: :published)
    EnumPost.create!(title: 'published two', status: :published)

    assert_equal 2, EnumPost.published.count
    assert_equal ['published one', 'published two'], EnumPost.published.order(:title).map(&:title)
  end

  def test_mapping_accessor
    assert_equal({ 'draft' => 0, 'published' => 1, 'archived' => 2 }, EnumPost.statuses)
  end

  def test_prefixed_enum_method_names
    post = EnumPost.new(title: 'a', role: :editor)
    assert post.role_editor?
    refute post.role_author?
    assert EnumPost.respond_to?(:role_editor)
  end

  def test_duplicate_raw_values_are_rejected_at_declaration
    assert_raises(ArgumentError) do
      Class.new(Facet::Orm::Model) do
        table_name :posts
        enum :status, { draft: 0, published: 0 }
      end
    end
  end

  def test_serializable_hash_shows_the_label_not_the_raw_value
    post = EnumPost.create!(title: 'a', status: :published, role: :editor)
    json = post.as_json
    assert_equal 'published', json['status']
    assert_equal 'editor', json['role']
  end

  def test_where_translates_symbol_label_to_raw_value
    draft = EnumPost.create!(title: 'a', status: :draft)
    EnumPost.create!(title: 'b', status: :published)

    assert_equal [draft], EnumPost.where(status: :draft).to_a
  end

  def test_where_translates_string_label_to_raw_value
    EnumPost.create!(title: 'a', status: :draft)
    published = EnumPost.create!(title: 'b', status: :published)

    assert_equal [published], EnumPost.where(status: 'published').to_a
  end

  def test_where_still_accepts_the_raw_stored_value_directly
    draft = EnumPost.create!(title: 'a', status: :draft)
    EnumPost.create!(title: 'b', status: :published)

    assert_equal [draft], EnumPost.where(status: 0).to_a
  end

  def test_where_translates_an_array_of_labels_for_in_style_matching
    draft = EnumPost.create!(title: 'a', status: :draft)
    published = EnumPost.create!(title: 'b', status: :published)
    EnumPost.create!(title: 'c', status: :archived)

    result = EnumPost.where(status: [:draft, 'published']).order(:title).to_a
    assert_equal [draft, published], result
  end

  def test_where_translates_labels_inside_an_operator_hash
    EnumPost.create!(title: 'a', status: :draft)
    published = EnumPost.create!(title: 'b', status: :published)
    archived = EnumPost.create!(title: 'c', status: :archived)

    result = EnumPost.where(status: { not_in: [:draft] }).order(:title).to_a
    assert_equal [published, archived], result

    gt_result = EnumPost.where(status: { gt: :draft }).order(:title).to_a
    assert_equal [published, archived], gt_result
  end

  def test_not_translates_enum_labels
    draft = EnumPost.create!(title: 'a', status: :draft)
    EnumPost.create!(title: 'b', status: :published)

    assert_equal [draft], EnumPost.not(status: :published).to_a
  end

  def test_find_by_translates_enum_labels
    published = EnumPost.create!(title: 'a', status: :published)
    assert_equal published, EnumPost.find_by(status: :published)
    assert_nil EnumPost.find_by(status: :archived)
  end

  def test_where_with_unknown_enum_label_raises_argument_error
    assert_raises(ArgumentError) { EnumPost.where(status: :deleted).to_a }
  end

  def test_where_on_non_enum_column_is_unaffected
    post = EnumPost.create!(title: 'unique-title', status: :draft)
    assert_equal [post], EnumPost.where(title: 'unique-title').to_a
  end

  def test_subclass_inherits_enum_definitions
    subclass = Class.new(EnumPost)
    subclass.store = @store
    subclass.table_name(:posts)
    Object.const_set(:EnumSubPost, subclass)
    post = EnumSubPost.new(title: 'a', status: :archived)
    assert_equal 'archived', post.status
    assert post.archived?
  ensure
    Object.send(:remove_const, :EnumSubPost) if Object.const_defined?(:EnumSubPost)
  end
end
