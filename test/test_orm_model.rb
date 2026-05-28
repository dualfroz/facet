require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmModelTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-model-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name price created_at updated_at])
    define_widget_class
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  def define_widget_class
    store = @store
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      self.store = store
    end
    Object.const_set(:Widget, widget_class)
  end

  def test_create_persists_and_returns_record
    widget = Widget.create(name: 'gizmo', price: 10)
    assert widget.persisted?
    refute_nil widget.id
    assert_equal 'gizmo', Widget.find(widget.id).name
  end

  def test_dynamic_attribute_accessors
    widget = Widget.new(name: 'gadget')
    assert_equal 'gadget', widget.name
    widget.name = 'renamed'
    assert_equal 'renamed', widget.name
  end

  def test_find_raises_for_missing_record
    assert_raises(Prism::Orm::RecordNotFound) { Widget.find(9999) }
  end

  def test_update_persists_new_values
    widget = Widget.create(name: 'gizmo', price: 10)
    widget.update(price: 25)
    assert_equal 25, Widget.find(widget.id).price
  end

  def test_destroy_removes_record
    widget = Widget.create(name: 'gizmo')
    id = widget.id
    widget.destroy
    assert widget.destroyed?
    assert_raises(Prism::Orm::RecordNotFound) { Widget.find(id) }
  end

  def test_reload_refreshes_attributes
    widget = Widget.create(name: 'gizmo', price: 10)
    Widget.find(widget.id).update(price: 99)
    widget.reload
    assert_equal 99, widget.price
  end

  def test_timestamps_are_touched_on_save
    widget = Widget.create(name: 'gizmo')
    refute_nil widget.created_at
    refute_nil widget.updated_at
    created_at = widget.created_at
    widget.update(price: 5)
    assert_equal created_at, widget.created_at
    refute_nil widget.updated_at
  end

  def test_equality_by_class_and_id
    widget = Widget.create(name: 'gizmo')
    same = Widget.find(widget.id)
    assert_equal widget, same
  end

  def test_save_fails_and_returns_false_when_invalid
    Widget.validates(:name, presence: true)
    widget = Widget.new(name: '')
    refute widget.save
    assert_includes widget.errors[:name], 'must be present'
  ensure
    Widget.validators.clear
  end

  def test_save_bang_raises_on_invalid_record
    Widget.validates(:name, presence: true)
    widget = Widget.new(name: '')
    assert_raises(Prism::Orm::RecordInvalid) { widget.save! }
  ensure
    Widget.validators.clear
  end

  def test_reset_schema_picks_up_columns_added_after_the_model_was_first_used
    Widget.new # forces load_schema! against the original column set
    @store.add_column(:widgets, :sku)
    Widget.reset_schema!

    widget = Widget.create(name: 'gizmo', sku: 'SKU-1')
    assert_equal 'SKU-1', widget.sku
  end
end
