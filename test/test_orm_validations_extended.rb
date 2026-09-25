require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmValidationsExtendedTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-validation-ext-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:products, %w[id name price quantity status])

    @product_class = Class.new(Facet::Orm::Model) do
      table_name :products
      validates_numericality_of :price, greater_than: 0
      validates_numericality_of :quantity, only_integer: true, greater_than_or_equal_to: 0
      validates_inclusion_of :status, in: %w[draft published archived]

      validate :name_must_not_be_shouting

      def name_must_not_be_shouting
        return unless name && name == name.upcase && name.match?(/[A-Z]/)
        errors.add(:name, 'must not be all caps')
      end
    end
    @product_class.store = @store
    Object.const_set(:Product, @product_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Product) if Object.const_defined?(:Product)
  end

  def test_numericality_rejects_non_numbers
    product = Product.new(name: 'widget', price: 'free', quantity: 1, status: 'draft')
    refute product.valid?
    assert_includes product.errors[:price], 'is not a number'
  end

  def test_numericality_enforces_greater_than
    product = Product.new(name: 'widget', price: 0, quantity: 1, status: 'draft')
    refute product.valid?
    assert_includes product.errors[:price], 'must be greater than 0'
  end

  def test_numericality_only_integer
    product = Product.new(name: 'widget', price: 5, quantity: 1.5, status: 'draft')
    refute product.valid?
    assert_includes product.errors[:quantity], 'must be an integer'
  end

  def test_numericality_passes_for_valid_number
    product = Product.new(name: 'widget', price: 9.99, quantity: 3, status: 'draft')
    assert product.valid?, product.errors.full_messages.join(', ')
  end

  def test_inclusion_rejects_value_outside_set
    product = Product.new(name: 'widget', price: 1, quantity: 1, status: 'deleted')
    refute product.valid?
    assert_includes product.errors[:status], 'is not included in the list'
  end

  def test_inclusion_accepts_value_in_set
    product = Product.new(name: 'widget', price: 1, quantity: 1, status: 'published')
    assert product.valid?, product.errors.full_messages.join(', ')
  end

  def test_exclusion_rejects_reserved_values
    klass = Class.new(Facet::Orm::Model) do
      table_name :products
      validates_exclusion_of :name, in: %w[admin root]
    end
    klass.store = @store
    reserved = klass.new(name: 'admin')
    refute reserved.valid?
    assert_includes reserved.errors[:name], 'is reserved'
  end

  def test_custom_validator_method_adds_error
    product = Product.new(name: 'SHOUT', price: 1, quantity: 1, status: 'draft')
    refute product.valid?
    assert_includes product.errors[:name], 'must not be all caps'
  end

  def test_custom_validator_block
    klass = Class.new(Facet::Orm::Model) do
      table_name :products
      validate { errors.add(:base, 'always invalid') if name == 'reject-me' }
    end
    klass.store = @store
    record = klass.new(name: 'reject-me')
    refute record.valid?
    assert_includes record.errors[:base], 'always invalid'
  end

  def test_custom_message_on_numericality
    klass = Class.new(Facet::Orm::Model) do
      table_name :products
      validates_numericality_of :price, greater_than: 0, message: 'needs a positive price'
    end
    klass.store = @store
    record = klass.new(name: 'x', price: -1)
    refute record.valid?
    assert_includes record.errors[:price], 'needs a positive price'
  end
end
