require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmRelationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-relation-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:items, %w[id name category])
    item_class = Class.new(Facet::Orm::Model) do
      table_name :items
    end
    item_class.store = @store
    Object.const_set(:Item, item_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Item) if Object.const_defined?(:Item)
  end

  def test_offset_skips_leading_rows
    %w[a b c d].each { |name| Item.create!(name: name) }
    names = Item.order(:name).offset(2).map(&:name)
    assert_equal %w[c d], names
  end

  def test_offset_combined_with_limit_paginates
    %w[a b c d e].each { |name| Item.create!(name: name) }
    page_two = Item.order(:name).offset(2).limit(2).map(&:name)
    assert_equal %w[c d], page_two
  end

  def test_chained_where_calls_combine_with_and_semantics
    Item.create!(name: 'match', category: 'tools')
    Item.create!(name: 'match', category: 'other')
    Item.create!(name: 'nope', category: 'tools')

    result = Item.where(name: 'match').where(category: 'tools').to_a
    assert_equal 1, result.size
    assert_equal 'match', result.first.name
  end

  def test_relation_is_enumerable
    Item.create!(name: 'b')
    Item.create!(name: 'a')
    assert_equal %w[a b], Item.order(:name).sort_by(&:name).map(&:name)
    assert_equal 2, Item.all.count
  end

  def test_exists_predicate
    refute Item.where(name: 'ghost').exists?
    Item.create!(name: 'ghost')
    assert Item.where(name: 'ghost').exists?
  end
end
