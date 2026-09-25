require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class OrmListPositionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-list-position-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:tasks, %w[id title position deleted_at])
    @store.create_table(:cards, %w[id title position board_id])

    task_class = Class.new(Facet::Orm::Model) do
      table_name :tasks
      acts_as_paranoid
      acts_as_list column: :position
    end
    card_class = Class.new(Facet::Orm::Model) do
      table_name :cards
      acts_as_list column: :position, scope: :board_id
    end
    plain_class = Class.new(Facet::Orm::Model) { table_name :tasks }

    [task_class, card_class].each { |klass| klass.store = @store }
    plain_class.store = @store
    Object.const_set(:Task, task_class)
    Object.const_set(:Card, card_class)
    Object.const_set(:PlainTask, plain_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Task Card PlainTask].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_a_model_that_never_called_acts_as_list_is_unaffected
    refute PlainTask.acts_as_list?
    assert Task.acts_as_list?
  end

  def test_fresh_records_are_appended_to_the_bottom_in_creation_order
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    assert_equal [1, 2, 3], [a, b, c].map(&:list_position)
  end

  def test_move_higher_swaps_with_the_previous_item_and_is_a_noop_at_the_top
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    b.move_higher
    assert_equal 1, b.list_position
    assert_equal 2, a.reload.list_position

    b.reload.move_higher
    assert_equal 1, b.list_position
    assert_equal 2, a.reload.list_position
  end

  def test_move_lower_swaps_with_the_next_item_and_is_a_noop_at_the_bottom
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    a.move_lower
    assert_equal 2, a.list_position
    assert_equal 1, b.reload.list_position

    b.reload.move_lower
    assert_equal 2, b.list_position
    assert_equal 1, a.reload.list_position
  end

  def test_move_lower_on_the_last_item_is_a_noop
    a = Task.create!(title: 'a')
    Task.create!(title: 'b')
    b2 = Task.find_by!(title: 'b')
    b2.move_lower
    assert_equal 2, b2.list_position
    assert_equal 1, a.reload.list_position
  end

  def test_move_higher_on_the_first_item_is_a_noop
    a = Task.create!(title: 'a')
    Task.create!(title: 'b')
    a.move_higher
    assert_equal 1, a.list_position
  end

  def test_first_and_last_in_list_predicates
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    assert a.first_in_list?
    refute a.last_in_list?
    assert c.last_in_list?
    refute c.first_in_list?
    refute b.first_in_list?
    refute b.last_in_list?
  end

  def test_move_to_top_and_move_to_bottom_reposition_and_shift_everyone_between
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    d = Task.create!(title: 'd')

    c.move_to_top
    assert_equal [1, 2, 3, 4], [c, a, b, d].map { |t| t.reload.list_position }

    a.reload.move_to_bottom
    assert_equal [1, 2, 3, 4], [c, b, d, a].map { |t| t.reload.list_position }
  end

  def test_insert_at_moves_an_item_to_an_arbitrary_middle_slot
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    d = Task.create!(title: 'd')

    d.insert_at(2)
    assert_equal [1, 2, 3, 4], [a, d, b, c].map { |t| t.reload.list_position }
  end

  def test_insert_at_on_a_record_that_is_not_persisted_raises
    task = Task.new(title: 'unsaved')
    assert_raises(Facet::Orm::RecordNotFound) { task.insert_at(1) }
  end

  def test_destroying_an_item_closes_the_gap_for_everyone_below_it
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    b.destroy
    assert_equal 1, a.reload.list_position
    assert_equal 2, c.reload.list_position
  end

  def test_soft_deleting_a_paranoid_item_also_closes_the_gap
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    b.destroy
    assert b.deleted?
    assert_equal 1, a.reload.list_position
    assert_equal 2, c.reload.list_position
  end

  def test_restoring_a_soft_deleted_item_reappends_it_to_the_bottom_not_its_old_slot
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')
    b.destroy
    d = Task.create!(title: 'd')
    assert_equal [1, 2, 3], [a.reload, c.reload, d.reload].map(&:list_position)

    restored = Task.only_deleted.find_by!(title: 'b')
    restored.restore
    assert_equal 4, restored.list_position
    assert_equal [1, 2, 3, 4], [a.reload, c.reload, d.reload, restored.reload].map(&:list_position).sort
  end

  def test_scoped_lists_are_independent_per_scope_value
    a1 = Card.create!(title: 'a1', board_id: 1)
    a2 = Card.create!(title: 'a2', board_id: 1)
    b1 = Card.create!(title: 'b1', board_id: 2)
    assert_equal 1, a1.list_position
    assert_equal 2, a2.list_position
    assert_equal 1, b1.list_position

    a1.move_lower
    assert_equal 1, b1.reload.list_position
  end

  def test_explicit_position_on_create_shifts_existing_siblings_down
    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    inserted = Task.create!(title: 'new-first', position: 1)
    assert_equal 1, inserted.list_position
    assert_equal 2, a.reload.list_position
    assert_equal 3, b.reload.list_position
  end

  def test_changing_the_scope_column_moves_a_record_between_lists_on_update
    a1 = Card.create!(title: 'a1', board_id: 1)
    a2 = Card.create!(title: 'a2', board_id: 1)
    a3 = Card.create!(title: 'a3', board_id: 1)
    b1 = Card.create!(title: 'b1', board_id: 2)

    a2.update!(board_id: 2)

    assert_equal 1, a1.reload.list_position
    assert_equal 2, a3.reload.list_position
    assert_equal 1, b1.reload.list_position
    assert_equal 2, a2.reload.list_position
  end

  def test_updating_without_touching_the_scope_column_leaves_position_alone
    a = Card.create!(title: 'a', board_id: 1)
    b = Card.create!(title: 'b', board_id: 1)
    a.update!(title: 'a renamed')
    assert_equal 1, a.list_position
    assert_equal 2, b.reload.list_position
  end

  def test_swap_list_position_with_is_racy_without_a_held_lock
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')

    a_read, a_wrote_read_signal = IO.pipe
    b_read, b_wrote_read_signal = IO.pipe

    pid_x = Process.fork do
      a_read.close
      b_wrote_read_signal.close
      x_self = Task.find(a.id)
      x_neighbor = Task.find(b.id)
      a_wrote_read_signal.write('r')
      a_wrote_read_signal.close
      b_read.read(1)
      b_read.close
      x_self.send(:swap_list_position_with, x_neighbor)
      exit!(0)
    end

    pid_y = Process.fork do
      a_wrote_read_signal.close
      b_read.close
      a_read.read(1)
      a_read.close
      y_self = Task.find(c.id)
      y_neighbor = Task.find(b.id)
      b_wrote_read_signal.write('r')
      b_wrote_read_signal.close
      y_self.send(:swap_list_position_with, y_neighbor)
      exit!(0)
    end

    [a_read, a_wrote_read_signal, b_read, b_wrote_read_signal].each(&:close)
    Process.waitpid(pid_x)
    Process.waitpid(pid_y)

    assert_equal [2, 2, 2], [a, b, c].map { |t| t.reload.list_position }.sort
  end

  def test_move_higher_and_move_lower_stay_race_free_under_real_concurrency
    skip 'fork not supported on this platform' unless Process.respond_to?(:fork)

    a = Task.create!(title: 'a')
    b = Task.create!(title: 'b')
    c = Task.create!(title: 'c')

    pid_x = Process.fork do
      Task.find(a.id).move_lower
      exit!(0)
    end
    pid_y = Process.fork do
      Task.find(c.id).move_higher
      exit!(0)
    end
    Process.waitpid(pid_x)
    Process.waitpid(pid_y)

    positions = [a, b, c].map { |t| t.reload.list_position }
    assert_equal [1, 2, 3], positions.sort, 'no duplicate or skipped positions after concurrent moves'
    assert_equal 3, positions.uniq.size
  end
end
