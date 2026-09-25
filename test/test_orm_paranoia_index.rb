require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmParanoiaIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-paranoia-index')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:tickets, %w[id title status deleted_at])

    ticket_class = Class.new(Facet::Orm::Model) do
      table_name :tickets
      acts_as_paranoid
    end
    ticket_class.store = @store
    Object.const_set(:ParanoidTicket, ticket_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :ParanoidTicket) if Object.const_defined?(:ParanoidTicket)
  end

  def test_indexed_where_on_a_paranoid_model_still_excludes_soft_deleted_rows
    @store.add_index(:tickets, :status)
    ParanoidTicket.create!(title: 'a', status: 'open')
    trashed = ParanoidTicket.create!(title: 'b', status: 'open')
    trashed.destroy

    visible = ParanoidTicket.where(status: 'open').to_a
    assert_equal ['a'], visible.map { |ticket| ticket['title'] }

    raw_hits = @store.lookup_by_index(:tickets, { 'status' => 'open' })
    assert_equal ['a', 'b'], raw_hits.map { |row| row['title'] }.sort
  end

  def test_add_column_backfill_indexes_a_soft_deleted_row_the_same_as_a_live_one
    @store.remove_column(:tickets, :status)

    id_live = @store.insert(:tickets, title: 'a')
    id_trashed = @store.insert(:tickets, title: 'b')
    @store.update(:tickets, id_trashed, 'deleted_at' => Time.now.utc)
    @store.add_index(:tickets, :status)

    @store.add_column(:tickets, :status, default: 'open')

    raw_hits = @store.lookup_by_index(:tickets, { 'status' => 'open' })
    assert_equal [id_live, id_trashed].sort, raw_hits.map { |row| row['id'] }.sort,
                 'add_column backfill must reindex every existing row, deleted or not'
    assert_equal ['a'], ParanoidTicket.where(status: 'open').to_a.map { |ticket| ticket['title'] },
                 'the paranoid scope on top of that same index lookup must still hide the trashed row'
  end

  def test_restore_brings_a_row_back_into_the_paranoid_scoped_index_lookup
    @store.add_index(:tickets, :status)
    trashed = ParanoidTicket.create!(title: 'b', status: 'open')
    trashed.destroy
    assert_equal [], ParanoidTicket.where(status: 'open').to_a

    trashed.restore

    assert_equal ['b'], ParanoidTicket.where(status: 'open').to_a.map { |ticket| ticket['title'] }
  end
end
