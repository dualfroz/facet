require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmTransactionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-tx-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:ledger, %w[id amount])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_successful_transaction_commits_every_write
    @store.transaction do
      @store.insert(:ledger, amount: 10)
      @store.insert(:ledger, amount: 20)
    end
    assert_equal [10, 20], @store.all(:ledger).map { |row| row['amount'] }
  end

  def test_failed_transaction_rolls_back_every_write
    assert_raises(RuntimeError) do
      @store.transaction do
        @store.insert(:ledger, amount: 10)
        @store.insert(:ledger, amount: 20)
        raise 'transfer failed midway'
      end
    end
    assert_empty @store.all(:ledger), 'no row from the aborted transaction should be visible'
  end

  def test_transaction_return_value_is_yielded_through
    result = @store.transaction { @store.insert(:ledger, amount: 5) }
    assert_equal 1, result
  end
end
