require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmPaginationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-pagination-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name position])
    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
    end
    widget_class.store = @store
    Object.const_set(:Widget, widget_class)

    25.times { |i| Widget.create!(name: "widget-#{i}", position: i) }
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  def test_default_per_page_is_twenty_five
    relation = Widget.order(:position).page(1)
    assert_equal 25, relation.to_a.size
    assert_equal 1, relation.total_pages
  end

  def test_per_page_limits_the_page_size
    relation = Widget.order(:position).page(1).per(10)
    assert_equal 10, relation.to_a.size
    assert_equal 'widget-0', relation.to_a.first.name
    assert_equal 'widget-9', relation.to_a.last.name
  end

  def test_second_page_offsets_correctly
    relation = Widget.order(:position).page(2).per(10)
    assert_equal 'widget-10', relation.to_a.first.name
    assert_equal 'widget-19', relation.to_a.last.name
  end

  def test_last_partial_page_has_the_remainder
    relation = Widget.order(:position).page(3).per(10)
    assert_equal 5, relation.to_a.size
  end

  def test_total_count_ignores_the_page_window
    relation = Widget.page(1).per(10)
    assert_equal 25, relation.total_count
    assert_equal 3, relation.total_pages
  end

  def test_current_page_and_navigation_helpers
    relation = Widget.page(2).per(10)
    assert_equal 2, relation.current_page
    assert_equal 1, relation.prev_page
    assert_equal 3, relation.next_page
    refute relation.first_page?
    refute relation.last_page?
  end

  def test_first_and_last_page_edges
    first = Widget.page(1).per(10)
    assert first.first_page?
    assert_nil first.prev_page

    last = Widget.page(3).per(10)
    assert last.last_page?
    assert_nil last.next_page
  end

  def test_page_number_is_clamped_to_at_least_one
    relation = Widget.page(0).per(10)
    assert_equal 1, relation.current_page
  end

  def test_out_of_range_page_returns_no_records_but_reports_totals
    relation = Widget.page(99).per(10)
    assert_empty relation.to_a
    assert relation.out_of_range?
    assert_equal 25, relation.total_count
  end

  def test_page_composes_with_where_and_order
    relation = Widget.where(position: (5..14).to_a).order(:position).page(1).per(5)
    assert_equal %w[widget-5 widget-6 widget-7 widget-8 widget-9], relation.to_a.map(&:name)
    assert_equal 10, relation.total_count
    assert_equal 2, relation.total_pages
  end

  def test_per_before_page_and_page_before_per_are_equivalent
    a = Widget.order(:position).per(4).page(2)
    b = Widget.order(:position).page(2).per(4)
    assert_equal a.to_a.map(&:id), b.to_a.map(&:id)
  end
end
