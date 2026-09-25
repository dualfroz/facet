require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmQueryBatchesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-query-batches')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:records, %w[id seq])
    record_class = Class.new(Facet::Orm::Model) do
      table_name :records
    end
    record_class.store = @store
    Object.const_set(:Rec, record_class)

    25.times { |i| Rec.create!(seq: i) }
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Rec) if Object.const_defined?(:Rec)
  end

  def test_find_each_yields_every_record_once
    seen = []
    Rec.order(:seq).find_each(batch_size: 7) { |record| seen << record.seq }
    assert_equal (0..24).to_a, seen
  end

  def test_find_each_without_block_returns_enumerator
    enum = Rec.order(:seq).find_each
    assert_kind_of Enumerator, enum
    assert_equal 25, enum.to_a.size
  end

  def test_find_in_batches_respects_batch_size
    batch_sizes = []
    Rec.order(:seq).find_in_batches(batch_size: 10) { |batch| batch_sizes << batch.size }
    assert_equal [10, 10, 5], batch_sizes
  end

  def test_find_in_batches_default_size_yields_single_batch_for_small_sets
    batches = []
    Rec.order(:seq).find_in_batches { |batch| batches << batch }
    assert_equal 1, batches.size
    assert_equal 25, batches.first.size
  end
end
