require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class OrmModelTransactionsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-model-tx')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:accounts, %w[id name balance])
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])

    account_class = Class.new(Facet::Orm::Model) { table_name :accounts }
    author_class = Class.new(Facet::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id', dependent: :destroy
    end
    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    [account_class, author_class, post_class].each { |klass| klass.store = @store }
    Object.const_set(:Account, account_class)
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Account Author Post].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_transaction_commits_every_write_made_by_multiple_records
    Account.transaction do
      Account.create!(name: 'alice', balance: 10)
      Account.create!(name: 'bob', balance: 20)
    end
    assert_equal [10, 20], Account.all.map(&:balance)
  end

  def test_exception_inside_transaction_rolls_back_every_write
    assert_raises(RuntimeError) do
      Account.transaction do
        Account.create!(name: 'alice', balance: 10)
        Account.create!(name: 'bob', balance: 20)
        raise 'transfer failed midway'
      end
    end
    assert_empty Account.all.to_a
  end

  def test_rollback_exception_aborts_silently_without_propagating
    result = Account.transaction do
      Account.create!(name: 'alice', balance: 10)
      raise Facet::Orm::Rollback
    end
    assert_nil result
    assert_empty Account.all.to_a
  end

  def test_transaction_can_be_entered_from_an_instance_and_from_a_different_model_class
    alice = Account.create!(name: 'alice', balance: 0)
    assert_raises(RuntimeError) do
      alice.transaction do
        alice.update!(balance: 100)
        Author.create!(name: 'ghost')
        raise 'boom'
      end
    end
    assert_equal 0, alice.reload.balance
    assert_empty Author.all.to_a
  end

  def test_after_commit_fires_once_for_a_standalone_save_with_no_explicit_transaction
    log = []
    Account.after_commit { log << [:commit, name] }
    Account.after_rollback { log << [:rollback, name] }
    Account.create!(name: 'alice', balance: 5)
    assert_equal [[:commit, 'alice']], log
  end

  def test_after_commit_fires_exactly_once_for_all_participants_of_an_explicit_transaction
    log = []
    Account.after_commit { log << name }
    Account.transaction do
      Account.create!(name: 'alice', balance: 1)
      Account.create!(name: 'bob', balance: 2)
    end
    assert_equal %w[alice bob], log.sort
  end

  def test_after_rollback_fires_instead_of_after_commit_when_the_transaction_raises
    committed = []
    rolled_back = []
    Account.after_commit { committed << name }
    Account.after_rollback { rolled_back << name }
    assert_raises(RuntimeError) do
      Account.transaction do
        Account.create!(name: 'alice', balance: 1)
        raise 'boom'
      end
    end
    assert_empty committed
    assert_equal ['alice'], rolled_back
  end

  def test_after_commit_on_filters_by_operation
    creates = []
    updates = []
    Account.after_commit(on: :create) { creates << name }
    Account.after_commit(on: :update) { updates << name }
    account = Account.create!(name: 'alice', balance: 1)
    account.update!(balance: 2)
    assert_equal ['alice'], creates
    assert_equal ['alice'], updates
  end

  def test_cascaded_dependent_destroy_shares_one_transaction_with_the_parent
    author = Author.create!(name: 'alice')
    Post.create!(title: 'a', author_id: author.id)
    Post.create!(title: 'b', author_id: author.id)

    Author.after_destroy { raise 'boom after destroy' }
    assert_raises(RuntimeError) { author.destroy }

    assert Author.find(author.id), 'the author row must survive the aborted transaction'
    assert_equal 2, Post.where(author_id: author.id).count,
                 'cascaded child deletes must roll back together with the parent'
  end

  def test_before_destroy_abort_never_reaches_the_store
    Author.before_destroy { throw :abort }
    author = Author.create!(name: 'alice')
    author.destroy
    refute author.destroyed?
    assert Author.find(author.id)
  end

  def test_plain_nested_transaction_still_flattens_and_rolls_back_everything
    assert_raises(RuntimeError) do
      Account.transaction do
        Account.create!(name: 'alice', balance: 10)
        Account.transaction do
          Account.create!(name: 'bob', balance: 20)
          raise 'boom'
        end
      end
    end
    assert_empty Account.all.to_a, 'a plain nested transaction is not a real savepoint'
  end

  def test_requires_new_rolls_back_only_the_inner_writes_and_lets_the_outer_commit
    Account.transaction do
      Account.create!(name: 'alice', balance: 10)
      assert_raises(RuntimeError) do
        Account.transaction(requires_new: true) do
          Account.create!(name: 'doomed', balance: 999)
          raise 'inner failure'
        end
      end
      Account.create!(name: 'bob', balance: 20)
    end
    assert_equal %w[alice bob], Account.all.map(&:name).sort
  end

  def test_requires_new_with_explicit_rollback_is_swallowed_and_outer_keeps_going
    Account.transaction do
      Account.create!(name: 'alice', balance: 10)
      result = Account.transaction(requires_new: true) do
        Account.create!(name: 'doomed', balance: 999)
        raise Facet::Orm::Rollback
      end
      assert_nil result
      Account.create!(name: 'bob', balance: 20)
    end
    assert_equal %w[alice bob], Account.all.map(&:name).sort
  end

  def test_requires_new_fires_after_rollback_immediately_without_waiting_for_the_outer_transaction
    log = []
    Account.after_commit { log << [:commit, name] }
    Account.after_rollback { log << [:rollback, name] }

    Account.transaction do
      Account.create!(name: 'alice', balance: 10)
      assert_raises(RuntimeError) do
        Account.transaction(requires_new: true) do
          Account.create!(name: 'doomed', balance: 999)
          raise 'inner failure'
        end
      end
      assert_equal [[:rollback, 'doomed']], log,
                   'the savepoint must have rolled back already, before the outer transaction has even finished'
      Account.create!(name: 'bob', balance: 20)
    end
    assert_equal [[:rollback, 'doomed'], [:commit, 'alice'], [:commit, 'bob']], log
  end

  def test_requires_new_without_a_surrounding_transaction_behaves_like_a_plain_transaction
    assert_raises(RuntimeError) do
      Account.transaction(requires_new: true) do
        Account.create!(name: 'alice', balance: 10)
        raise 'boom'
      end
    end
    assert_empty Account.all.to_a
  end

  def test_outer_rollback_after_a_committed_savepoint_still_undoes_the_savepoint_writes
    assert_raises(RuntimeError) do
      Account.transaction do
        Account.transaction(requires_new: true) do
          Account.create!(name: 'alice', balance: 10)
        end
        raise 'outer failure'
      end
    end
    assert_empty Account.all.to_a, 'a released savepoint is not a commit point on its own'
  end
end
