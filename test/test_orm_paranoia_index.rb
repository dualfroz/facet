require 'minitest/autorun'
require 'prism'
require 'tmpdir'

# Store has no concept of paranoia at all (see Paranoia#paranoid_scope - it is
# just a plain `relation.where(deleted_at: nil)` bolted on by Model.all/.count).
# Store#lookup_by_index only ever requires an index's OWN columns to be present
# in the equality Hash it is given, never the reverse, so a `status`-only index
# is used even when the real condition tree also carries `deleted_at: nil` from
# the paranoid scope - the index itself returns every row with that status,
# soft-deleted rows included, and Relation#rows re-checks the FULL condition
# against every index-returned candidate before returning (see
# ConditionNode#indexed_candidates). Store#add_column's backfill
# (rebuild_indexes_covering) iterates every row in definition[:rows], which
# still holds soft-deleted rows too (paranoia never physically removes them),
# so a column added after some rows were already trashed still gets those rows
# correctly indexed. None of this required a code change - it was already true
# by construction - but nothing had exercised paranoia and secondary indexes
# together until now (see prism-postep.md session 82 "kierunki dalsze").
class OrmParanoiaIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-paranoia-index')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:tickets, %w[id title status deleted_at])

    ticket_class = Class.new(Prism::Orm::Model) do
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

    # The raw index is paranoia-blind by design: both rows come back for
    # status "open", the soft-deleted one included. Correctness comes from
    # Relation#rows re-filtering index candidates through the whole
    # condition (deleted_at: nil included), not from the index excluding it.
    raw_hits = @store.lookup_by_index(:tickets, { 'status' => 'open' })
    assert_equal ['a', 'b'], raw_hits.map { |row| row['title'] }.sort
  end

  def test_add_column_backfill_indexes_a_soft_deleted_row_the_same_as_a_live_one
    @store.remove_column(:tickets, :status)

    id_live = @store.insert(:tickets, title: 'a')
    id_trashed = @store.insert(:tickets, title: 'b')
    @store.update(:tickets, id_trashed, 'deleted_at' => Time.now.utc)
    # Index the column BEFORE it exists (like OrmIndexColumnMigrationTest's
    # own add_column-backfill tests) so add_column's rebuild is the only
    # thing that can possibly populate this index, for either row.
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
