require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmIdLookupIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-id-lookup-index-store')
    @store = CountingIdIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id sku])
    @a = @store.insert(:widgets, sku: 'AAA')
    @b = @store.insert(:widgets, sku: 'BBB')

    widget_class = Class.new(Facet::Orm::Model) { table_name :widgets }
    widget_class.store = @store
    Object.const_set(:IdLookupWidget, widget_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :IdLookupWidget) if Object.const_defined?(:IdLookupWidget)
  end

  def test_lookup_by_index_answers_a_bare_id_equality_without_any_registered_index
    matches = @store.lookup_by_index(:widgets, { 'id' => @a })
    refute_nil matches, 'a plain id equality must never report "no index" (nil means fall back to a full scan)'
    assert_equal ['AAA'], matches.map { |row| row['sku'] }
  end

  def test_lookup_by_index_on_a_missing_id_is_an_empty_hit_not_a_scan_signal
    assert_equal [], @store.lookup_by_index(:widgets, { 'id' => @a + 999 })
  end

  def test_extra_equality_keys_alongside_id_are_still_resolved_by_id_alone
    matches = @store.lookup_by_index(:widgets, { 'id' => @a, 'sku' => 'WRONG' })
    assert_equal ['AAA'], matches.map { |row| row['sku'] }
  end

  def test_model_find_by_id_never_scans
    @store.reset_counts!
    widget = IdLookupWidget.find_by(id: @a)
    assert_equal 'AAA', widget.sku
    assert_equal 0, @store.scan_count
    assert_equal 1, @store.id_index_hits
  end

  def test_where_id_first_never_scans_even_with_an_unrelated_condition_chained_on
    @store.reset_counts!
    widget = IdLookupWidget.where(id: @a).where(sku: 'AAA').first
    assert_equal 'AAA', widget.sku
    assert_equal 0, @store.scan_count
  end

  def test_find_by_id_for_a_nonexistent_row_never_scans
    @store.reset_counts!
    assert_nil IdLookupWidget.find_by(id: @a + 999)
    assert_equal 0, @store.scan_count
  end
end

class CountingIdIndexStore < Facet::Orm::Store
  attr_reader :scan_count, :id_index_hits

  def initialize(*args)
    super
    @scan_count = 0
    @id_index_hits = 0
  end

  def all(table)
    @scan_count += 1
    super
  end

  def lookup_by_index(table, equalities)
    result = super
    @id_index_hits += 1 if !result.nil? && equalities.key?('id')
    result
  end

  def reset_counts!
    @scan_count = 0
    @id_index_hits = 0
  end
end
