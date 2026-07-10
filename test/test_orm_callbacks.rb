require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmCallbacksTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-callbacks-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name])
    @log = []
    log = @log
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      validates :name, presence: true

      before_validation { log << :before_validation }
      after_validation { log << :after_validation }
      before_save { log << :before_save }
      after_save { log << :after_save }
      before_create { log << :before_create }
      after_create { log << :after_create }
      before_update { log << :before_update }
      after_update { log << :after_update }
      before_destroy { log << :before_destroy }
      after_destroy { log << :after_destroy }
    end
    widget_class.store = @store
    Object.const_set(:Widget, widget_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  def test_full_callback_order_on_create
    Widget.create!(name: 'gizmo')
    assert_equal %i[before_validation after_validation before_save before_create after_create after_save], @log
  end

  def test_full_callback_order_on_update
    widget = Widget.create!(name: 'gizmo')
    @log.clear
    widget.update!(name: 'sprocket')
    assert_equal %i[before_validation after_validation before_save before_update after_update after_save], @log
  end

  def test_destroy_runs_before_and_after_destroy
    widget = Widget.create!(name: 'gizmo')
    @log.clear
    widget.destroy
    assert_equal %i[before_destroy after_destroy], @log
    assert widget.destroyed?
  end

  def test_before_save_abort_halts_the_chain_and_leaves_record_unsaved
    Widget.before_save { throw :abort }
    widget = Widget.new(name: 'gizmo')
    refute widget.save
    assert widget.new_record?
    refute_includes @log, :before_create
    refute_includes @log, :after_save
  end

  def test_before_destroy_abort_keeps_the_record
    Widget.before_destroy { throw :abort }
    widget = Widget.create!(name: 'gizmo')
    @log.clear
    widget.destroy
    refute widget.destroyed?
    assert Widget.find(widget.id)
    refute_includes @log, :after_destroy
  end

  def test_before_validation_abort_makes_the_record_invalid_without_running_validators
    Widget.before_validation { throw :abort }
    widget = Widget.new(name: 'gizmo')
    refute widget.valid?
    assert_empty widget.errors
  end

  def test_symbol_callback_can_mutate_the_record
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      before_save :normalize_name

      def normalize_name
        self.name = name.to_s.strip.downcase
      end
    end
    widget_class.store = @store
    widget = widget_class.create!(name: '  LOUD  ')
    assert_equal 'loud', widget.reload.name
  end

  def test_callbacks_are_inherited_and_run_base_before_subclass
    log = @log
    subclass = Class.new(Widget) do
      table_name :widgets
      before_save { log << :subclass_before_save }
    end
    subclass.store = @store
    subclass.create!(name: 'gizmo')
    before_save_calls = @log.select { |entry| entry == :before_save || entry == :subclass_before_save }
    assert_equal %i[before_save subclass_before_save], before_save_calls
  end
end
