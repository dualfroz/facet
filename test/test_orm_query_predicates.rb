require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmQueryPredicatesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-query-predicates')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:products, %w[id name price stock])
    product_class = Class.new(Prism::Orm::Model) do
      table_name :products
    end
    product_class.store = @store
    Object.const_set(:Product, product_class)

    Product.create!(name: 'Widget', price: 10, stock: 5)
    Product.create!(name: 'Gadget', price: 25, stock: 0)
    Product.create!(name: 'Gizmo', price: 40, stock: 12)
    Product.create!(name: nil, price: 15, stock: 3)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Product) if Object.const_defined?(:Product)
  end

  def test_gt_operator
    assert_equal %w[Gadget Gizmo], Product.where(price: { gt: 15 }).order(:name).pluck(:name)
  end

  def test_gte_operator
    assert_equal %w[Gadget Gizmo], Product.where(price: { gte: 25 }).order(:name).pluck(:name)
  end

  def test_lt_operator
    assert_equal ['Widget'], Product.where(price: { lt: 15 }).pluck(:name)
  end

  def test_lte_operator
    assert_equal %w[Widget], Product.where(price: { lte: 10 }).pluck(:name)
  end

  def test_ne_operator
    result = Product.where(stock: { ne: 0 }).count
    assert_equal 3, result
  end

  def test_combined_operators_in_same_hash
    matches = Product.where(price: { gt: 15, lt: 40 }).order(:name).pluck(:name)
    assert_equal %w[Gadget], matches
  end

  def test_in_operator
    assert_equal %w[Gadget Widget], Product.where(price: { in: [10, 25] }).order(:name).pluck(:name)
  end

  def test_not_in_operator
    assert_equal %w[Gizmo], Product.where(price: { not_in: [10, 25, 15] }).pluck(:name)
  end

  def test_like_operator_supports_percent_wildcard
    assert_equal %w[Gadget Gizmo], Product.where(name: { like: 'g%' }).order(:name).pluck(:name)
  end

  def test_like_operator_is_case_insensitive
    assert_equal %w[Widget], Product.where(name: { like: 'WIDGET' }).pluck(:name)
  end

  def test_not_like_operator
    names = Product.where(name: { not_like: 'g%' }).pluck(:name)
    assert_equal %w[Widget], names
  end

  def test_is_null_true
    assert_equal 1, Product.where(name: { is_null: true }).count
  end

  def test_is_null_false
    assert_equal 3, Product.where(name: { is_null: false }).count
  end

  def test_unknown_operator_raises
    error = assert_raises(Prism::Orm::Query::Predicates::UnknownOperator) do
      Product.where(price: { bogus: 1 }).to_a
    end
    assert_match(/bogus/, error.message)
  end
end
