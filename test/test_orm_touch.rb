require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmTouchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-touch-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name created_at updated_at published_at])
    @store.create_table(:gadgets, %w[id name])

    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
    end
    widget_class.store = @store
    Object.const_set(:Widget, widget_class)

    gadget_class = Class.new(Facet::Orm::Model) do
      table_name :gadgets
    end
    gadget_class.store = @store
    Object.const_set(:Gadget, gadget_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Widget Gadget].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_touch_bumps_updated_at_on_the_stored_row
    widget = Widget.create!(name: 'gizmo')
    original = widget.updated_at
    sleep 0.01
    widget.touch

    assert widget.updated_at > original
    assert_equal widget.updated_at, widget.reload.updated_at
  end

  def test_touch_does_not_run_validations
    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
      validates :name, presence: true
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')
    widget.name = nil
    refute widget.valid?

    widget.touch

    assert_equal 'gizmo', widget.reload.name
  end

  def test_touch_accepts_extra_attribute_names
    widget = Widget.create!(name: 'gizmo')
    refute widget.published_at

    widget.touch(:published_at)

    assert widget.published_at
    assert_equal widget.published_at, widget.reload.published_at
  end

  def test_touch_runs_after_touch_callback
    log = []
    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
      after_touch { log << :after_touch }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')

    widget.touch

    assert_equal [:after_touch], log
  end

  def test_touch_does_not_run_before_save_callbacks
    log = []
    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
      before_save { log << :before_save }
      after_save { log << :after_save }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')
    log.clear

    widget.touch

    assert_empty log
  end

  def test_touch_on_a_new_record_raises
    widget = Widget.new(name: 'gizmo')
    assert_raises(Facet::Orm::RecordNotFound) { widget.touch }
  end

  def test_touch_on_a_destroyed_record_raises
    widget = Widget.create!(name: 'gizmo')
    widget.destroy
    assert_raises(Facet::Orm::RecordNotFound) { widget.touch }
  end

  def test_touch_without_updated_at_column_and_no_names_is_a_no_op
    gadget = Gadget.create!(name: 'thing')
    assert_same gadget, gadget.touch
  end

  def test_touch_busts_cache_key
    widget = Widget.create!(name: 'gizmo')
    original_key = widget.cache_key
    sleep 1.01

    widget.touch

    refute_equal original_key, widget.cache_key
  end

  def test_touch_bumps_lock_version_when_optimistic_locking_is_enabled
    @store.create_table(:locked_widgets, %w[id name updated_at lock_version])
    locked_class = Class.new(Facet::Orm::Model) do
      table_name :locked_widgets
    end
    locked_class.store = @store
    widget = locked_class.create!(name: 'gizmo')
    assert_equal 0, widget.lock_version

    widget.touch

    assert_equal 1, widget.lock_version
    assert_equal 1, widget.reload.lock_version
  end

  def test_touch_raises_stale_object_error_on_lock_version_mismatch
    @store.create_table(:locked_widgets, %w[id name updated_at lock_version])
    locked_class = Class.new(Facet::Orm::Model) do
      table_name :locked_widgets
    end
    locked_class.store = @store
    widget = locked_class.create!(name: 'gizmo')
    stale_copy = locked_class.find(widget.id)
    widget.touch

    assert_raises(Facet::Orm::StaleObjectError) { stale_copy.touch }
  end
end
