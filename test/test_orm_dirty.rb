require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmDirtyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-dirty-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name notes])
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
    end
    widget_class.store = @store
    Object.const_set(:Widget, widget_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  def test_new_record_shows_assigned_attributes_as_changed
    widget = Widget.new(name: 'gizmo')
    assert widget.changed?
    assert_includes widget.changed, 'name'
    assert_equal [nil, 'gizmo'], widget.changes['name']
  end

  def test_persisted_record_is_clean_right_after_load
    widget = Widget.create!(name: 'gizmo')
    refute widget.changed?
    reloaded = Widget.find(widget.id)
    refute reloaded.changed?
    assert_empty reloaded.changes
  end

  def test_setting_an_attribute_marks_it_changed_with_old_and_new_value
    widget = Widget.create!(name: 'gizmo')
    widget.name = 'sprocket'
    assert widget.changed?
    assert widget.attribute_changed?(:name)
    assert_equal 'gizmo', widget.attribute_was(:name)
    assert_equal %w[gizmo sprocket], widget.attribute_change(:name)
    refute widget.attribute_changed?(:notes)
  end

  def test_setting_an_attribute_back_to_its_original_value_clears_the_change
    widget = Widget.create!(name: 'gizmo')
    widget.name = 'sprocket'
    widget.name = 'gizmo'
    refute widget.changed?
    refute widget.attribute_changed?(:name)
  end

  def test_restore_attributes_reverts_unsaved_changes
    widget = Widget.create!(name: 'gizmo', notes: 'first')
    widget.name = 'sprocket'
    widget.notes = 'second'
    widget.restore_attributes(['name'])
    assert_equal 'gizmo', widget.name
    assert_equal 'second', widget.notes
    assert widget.changed?
    widget.restore_attributes
    refute widget.changed?
    assert_equal 'first', widget.notes
  end

  def test_save_clears_current_changes_and_populates_saved_changes
    widget = Widget.create!(name: 'gizmo')
    widget.name = 'sprocket'
    widget.save!
    refute widget.changed?
    assert widget.saved_change_to_attribute?('name')
    assert_equal %w[gizmo sprocket], widget.saved_change_to_attribute('name')
    assert_equal %w[gizmo sprocket], widget.saved_changes['name']
  end

  def test_saved_changes_on_create_shows_nil_to_assigned_value
    widget = Widget.create!(name: 'gizmo')
    assert_equal [nil, 'gizmo'], widget.saved_changes['name']
  end

  def test_saving_with_no_changes_yields_empty_saved_changes
    widget = Widget.create!(name: 'gizmo')
    widget.save!
    assert_empty widget.saved_changes
  end

  def test_update_only_reports_the_actually_different_attribute
    widget = Widget.create!(name: 'gizmo', notes: 'first')
    widget.update!(name: 'gizmo', notes: 'second')
    assert_equal %w[notes], widget.saved_changes.keys
  end

  def test_reload_discards_unsaved_changes
    widget = Widget.create!(name: 'gizmo')
    widget.name = 'sprocket'
    widget.reload
    assert_equal 'gizmo', widget.name
    refute widget.changed?
  end

  def test_before_save_callback_can_inspect_pending_changes
    seen = []
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      before_save { seen << attribute_changed?(:name) }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')
    widget.update!(name: 'sprocket')
    widget.save!
    assert_equal [true, true, false], seen
  end

  def test_touching_updated_at_column_is_itself_tracked_as_a_change
    @store.create_table(:stamped, %w[id name updated_at])
    stamped_class = Class.new(Prism::Orm::Model) { table_name :stamped }
    stamped_class.store = @store
    record = stamped_class.create!(name: 'a')
    assert record.saved_change_to_attribute?('updated_at')
  end
end
