require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmHasOneThroughTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-has-one-through-store')
    @store = CountingHasOneThroughStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:suppliers, %w[id name])
    @store.create_table(:accounts, %w[id supplier_id plan])
    @store.create_table(:account_histories, %w[id account_id notes])

    supplier_class = Class.new(Prism::Orm::Model) do
      table_name :suppliers
      has_one :account, class_name: 'Account', foreign_key: 'supplier_id'
      has_one :account_history, through: :account
    end
    account_class = Class.new(Prism::Orm::Model) do
      table_name :accounts
      belongs_to :supplier, class_name: 'Supplier', foreign_key: 'supplier_id'
      has_one :account_history, class_name: 'AccountHistory', foreign_key: 'account_id'
    end
    history_class = Class.new(Prism::Orm::Model) do
      table_name :account_histories
      belongs_to :account, class_name: 'Account', foreign_key: 'account_id'
      has_one :supplier, through: :account
    end
    [supplier_class, account_class, history_class].each { |klass| klass.store = @store }
    Object.const_set(:Supplier, supplier_class)
    Object.const_set(:Account, account_class)
    Object.const_set(:AccountHistory, history_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Supplier Account AccountHistory].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_has_one_through_reads_source_off_a_has_one_through_record
    supplier = Supplier.create!(name: 'acme')
    account = Account.create!(supplier_id: supplier.id, plan: 'gold')
    history = AccountHistory.create!(account_id: account.id, notes: 'upgraded')

    assert_equal history.id, supplier.account_history.id
  end

  def test_has_one_through_reads_source_off_a_belongs_to_through_record
    supplier = Supplier.create!(name: 'acme')
    account = Account.create!(supplier_id: supplier.id, plan: 'gold')
    history = AccountHistory.create!(account_id: account.id, notes: 'upgraded')

    assert_equal supplier.id, history.supplier.id
  end

  def test_has_one_through_returns_nil_without_through_record
    supplier = Supplier.create!(name: 'lonely')
    assert_nil supplier.account_history
  end

  def test_has_one_through_returns_nil_when_through_exists_but_source_missing
    supplier = Supplier.create!(name: 'acme')
    Account.create!(supplier_id: supplier.id, plan: 'gold')
    assert_nil supplier.account_history
  end

  def test_has_one_through_honors_explicit_source_when_name_differs
    history_with_alias = Class.new(Prism::Orm::Model) do
      table_name :account_histories
      belongs_to :account, class_name: 'Account', foreign_key: 'account_id'
      has_one :owner, through: :account, source: :supplier
    end
    history_with_alias.store = @store

    supplier = Supplier.create!(name: 'acme')
    account = Account.create!(supplier_id: supplier.id, plan: 'gold')
    record = history_with_alias.create!(account_id: account.id, notes: 'n/a')

    assert_equal supplier.id, record.owner.id
  end

  def test_has_one_through_rejects_dependent_option
    error = assert_raises(ArgumentError) do
      Class.new(Prism::Orm::Model) do
        table_name :suppliers
        has_one :account, class_name: 'Account', foreign_key: 'supplier_id'
        has_one :account_history, through: :account, dependent: :destroy
      end
    end
    assert_match(/dependent/, error.message)
  end

  def test_includes_has_one_through_avoids_n_plus_one_queries
    3.times do |i|
      supplier = Supplier.create!(name: "supplier#{i}")
      account = Account.create!(supplier_id: supplier.id, plan: 'gold')
      AccountHistory.create!(account_id: account.id, notes: "notes#{i}")
    end
    lonely = Supplier.create!(name: 'no account')

    @store.reset_query_count!
    suppliers = Supplier.all.includes(:account_history).to_a
    baseline = @store.query_count

    notes = suppliers.map { |supplier| supplier.account_history&.notes }
    assert_equal baseline, @store.query_count,
      "expected preloaded #account_history to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal ['notes0', 'notes1', 'notes2', nil], notes.compact.sort + [nil]
    assert_includes suppliers.map(&:name), lonely.name
  end

  # Mirrors test_includes_has_one_through_avoids_n_plus_one_queries above,
  # but from the AccountHistory side where the through step (:account) is a
  # belongs_to rather than a has_one - exercises the `when :belongs_to then
  # preload_belongs_to(...)` branch in preload_has_one_through specifically,
  # which the has_one-through variant above never touches.
  def test_includes_has_one_through_by_belongs_to_avoids_n_plus_one_queries
    3.times do |i|
      supplier = Supplier.create!(name: "supplier#{i}")
      account = Account.create!(supplier_id: supplier.id, plan: 'gold')
      AccountHistory.create!(account_id: account.id, notes: "notes#{i}")
    end

    @store.reset_query_count!
    histories = AccountHistory.all.includes(:supplier).to_a
    baseline = @store.query_count

    names = histories.map { |history| history.supplier.name }.sort
    assert_equal baseline, @store.query_count,
      "expected preloaded #supplier to be free, but it issued #{@store.query_count - baseline} more queries"
    assert_equal %w[supplier0 supplier1 supplier2], names
  end

  def test_includes_has_one_through_unknown_through_raises
    broken_class = Class.new(Prism::Orm::Model) do
      table_name :suppliers
      has_one :account_history, through: :nonexistent
    end
    broken_class.store = @store
    broken_class.create!(name: 'x')
    assert_raises(ArgumentError) { broken_class.all.includes(:account_history).to_a }
  end

  def test_includes_has_one_through_rejects_has_many_through_association
    broken_class = Class.new(Prism::Orm::Model) do
      table_name :suppliers
      has_many :accounts, class_name: 'Account', foreign_key: 'supplier_id'
      has_one :account_history, through: :accounts
    end
    broken_class.store = @store
    broken_class.create!(name: 'x')
    assert_raises(ArgumentError) { broken_class.all.includes(:account_history).to_a }
  end
end

# Wraps Store#all/#find to count reads, mirroring CountingThroughStore in
# test_orm_has_many_through.rb so this file has no load-order dependency.
class CountingHasOneThroughStore < Prism::Orm::Store
  def initialize(*)
    super
    @query_count = 0
  end

  attr_reader :query_count

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
