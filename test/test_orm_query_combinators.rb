require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmQueryCombinatorsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-query-combinators')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:tickets, %w[id title status priority])
    ticket_class = Class.new(Facet::Orm::Model) do
      table_name :tickets
    end
    ticket_class.store = @store
    Object.const_set(:Ticket, ticket_class)

    Ticket.create!(title: 'a', status: 'open', priority: 'low')
    Ticket.create!(title: 'b', status: 'open', priority: 'high')
    Ticket.create!(title: 'c', status: 'closed', priority: 'high')
    Ticket.create!(title: 'd', status: 'closed', priority: 'low')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Ticket) if Object.const_defined?(:Ticket)
  end

  def test_not_excludes_matching_rows
    titles = Ticket.where(status: 'open').not(priority: 'low').pluck(:title)
    assert_equal ['b'], titles
  end

  def test_model_level_not_shorthand
    titles = Ticket.not(status: 'open').order(:title).pluck(:title)
    assert_equal %w[c d], titles
  end

  def test_or_combines_two_relations
    titles = Ticket.where(status: 'open').or(Ticket.where(priority: 'high')).order(:title).pluck(:title)
    assert_equal %w[a b c], titles
  end

  def test_or_with_plain_hash
    titles = Ticket.where(status: 'closed').or(priority: 'high').order(:title).pluck(:title)
    assert_equal %w[b c d], titles
  end

  def test_chained_and_or_and_not
    titles = Ticket.where(status: 'open').not(priority: 'low').or(Ticket.where(status: 'closed').not(priority: 'high'))
                   .order(:title).pluck(:title)
    assert_equal %w[b d], titles
  end

  def test_none_returns_empty_relation_without_touching_store
    relation = Ticket.none
    assert_equal 0, relation.count
    assert_equal [], relation.to_a
    refute relation.exists?
  end

  def test_where_still_ands_across_chained_calls
    titles = Ticket.where(status: 'open').where(priority: 'high').pluck(:title)
    assert_equal ['b'], titles
  end
end
