require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmQueryAggregationsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-query-aggregations')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:orders, %w[id customer amount])
    order_class = Class.new(Facet::Orm::Model) do
      table_name :orders
    end
    order_class.store = @store
    Object.const_set(:Order, order_class)

    Order.create!(customer: 'alice', amount: 10)
    Order.create!(customer: 'alice', amount: 30)
    Order.create!(customer: 'bob', amount: 5)
    Order.create!(customer: 'bob', amount: 15)
    Order.create!(customer: 'carol', amount: nil)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Order) if Object.const_defined?(:Order)
  end

  def test_sum
    assert_equal 40, Order.where(customer: 'alice').sum(:amount)
  end

  def test_sum_ignores_nil_values
    assert_equal 60, Order.sum(:amount)
  end


  def test_average
    assert_equal 20.0, Order.where(customer: 'alice').average(:amount)
  end

  def test_average_on_empty_relation_is_nil
    assert_nil Order.where(customer: 'nobody').average(:amount)
  end

  def test_minimum_and_maximum
    assert_equal 5, Order.minimum(:amount)
    assert_equal 30, Order.maximum(:amount)
  end

  def test_group_returns_records_bucketed_by_column
    grouped = Order.group(:customer)
    assert_equal %w[alice bob carol].sort, grouped.keys.sort
    assert_equal 2, grouped['alice'].size
    assert_kind_of Order, grouped['alice'].first
  end

  def test_group_count
    counts = Order.all.group_count(:customer)
    assert_equal 2, counts['alice']
    assert_equal 2, counts['bob']
    assert_equal 1, counts['carol']
  end

  def test_pick_single_column
    assert_equal 10, Order.where(customer: 'alice').order(:amount).pick(:amount)
  end

  def test_pick_multiple_columns
    row = Order.where(customer: 'bob').order(:amount).pick(:customer, :amount)
    assert_equal ['bob', 5], row
  end

  def test_ids_plucks_primary_keys
    ids = Order.where(customer: 'alice').ids
    assert_equal 2, ids.size
    assert(ids.all? { |id| id.is_a?(Integer) })
  end

  def test_distinct_dedupes_plucked_column_values
    Order.create!(customer: 'alice', amount: 10)
    distinct_amounts = Order.where(customer: 'alice').distinct.pluck(:amount)
    assert_equal [10, 30], distinct_amounts.sort
  end

  def test_without_distinct_pluck_keeps_duplicates
    Order.create!(customer: 'alice', amount: 10)
    amounts = Order.where(customer: 'alice').pluck(:amount).sort
    assert_equal [10, 10, 30], amounts
  end
end
