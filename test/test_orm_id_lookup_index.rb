require 'minitest/autorun'
require 'prism'
require 'tmpdir'

# `find_by(id: x)`/`where(id: x).first` go through Relation#rows exactly like
# any other equality lookup, which used to mean Store#lookup_by_index had to
# find a registered secondary index covering the 'id' column - but no
# framework code ever calls `add_index(table, :id)` (id is the primary key,
# already a Hash key on definition[:rows]), so that search always failed and
# silently fell back to a full table scan (Store#all). This was real, live
# behavior, not a theoretical gap: Prism::Authenticatable#current_user calls
# `authenticatable_model.find_by(id: id)` on every single authenticated
# request (lib/prism/authenticatable.rb), and examples/blog's
# ApplicationController#comment_post_label/#comment_post_linkable? call
# `Post.with_deleted.find_by(id: comment.post_id)` once per rendered comment
# row - both were full-scanning their table on every hit before this fix
# (discovered via examples/blog's new AccountController#moderation page,
# which renders several such rows per response and made the N full scans
# impossible to miss in the sql.prism log). #lookup_by_index_in already had
# this exact same "id is always indexed for free" special case for IN-lists
# (see its own comment) - this closes the matching gap for a plain scalar
# equality.
class OrmIdLookupIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-id-lookup-index-store')
    @store = CountingIdIndexStore.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id sku])
    @a = @store.insert(:widgets, sku: 'AAA')
    @b = @store.insert(:widgets, sku: 'BBB')

    widget_class = Class.new(Prism::Orm::Model) { table_name :widgets }
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
    # No index exists on `sku`, and the wrong sku is paired with the right
    # id - the id lookup still returns the row (Relation#rows re-checks the
    # full condition afterward and would reject it there, not here).
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

# Same shape as CountingFkIndexStore (test_orm_has_many_foreign_key_index.rb)
# plus a counter specifically for id-equality hits, since #lookup_by_index is
# the one method under test here rather than #lookup_by_index_in.
class CountingIdIndexStore < Prism::Orm::Store
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
