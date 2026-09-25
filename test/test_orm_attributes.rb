require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'json'

class OrmAttributesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-attributes-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id title featured views price published_at])
    widget_class = Class.new(Facet::Orm::Model) do
      table_name :widgets
      attribute :featured, :boolean, default: false
      attribute :views, :integer
      attribute :price, :float
      attribute :published_at, :datetime
    end
    widget_class.store = @store
    Object.const_set(:Widget, widget_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
    Object.send(:remove_const, :Gadget) if Object.const_defined?(:Gadget)
    Object.send(:remove_const, :SpecialGadget) if Object.const_defined?(:SpecialGadget)
  end

  def test_string_form_input_casts_to_the_declared_type_on_write
    widget = Widget.new(featured: '1', views: '42', price: '9.5')
    assert_equal true, widget.featured
    assert_equal 42, widget.views
    assert_in_delta 9.5, widget.price
  end

  def test_cast_value_is_what_actually_gets_stored_not_the_raw_string
    widget = Widget.create!(title: 'a', featured: '1', views: '42')
    assert_equal true, widget.to_h['featured']
    assert_equal 42, widget.to_h['views']
  end

  def test_default_is_applied_when_the_attribute_is_omitted
    assert_equal false, Widget.new(title: 'a').featured
  end

  def test_an_explicit_value_wins_over_the_default
    assert_equal true, Widget.new(title: 'a', featured: 'yes').featured
  end

  def test_default_survives_a_real_save_and_reload
    widget = Widget.create!(title: 'a')
    reloaded = Widget.find(widget.id)
    assert_equal false, reloaded.featured
  end

  def test_proc_default_is_evaluated_per_instance
    Object.const_set(:Gadget, Class.new(Facet::Orm::Model) do
      table_name :widgets
      attribute :views, :integer, default: -> { 7 }
    end)
    Gadget.store = @store
    assert_equal 7, Gadget.new(title: 'a').views
    assert_equal 7, Gadget.new(title: 'b').views
  end

  def test_reloading_a_saved_record_returns_real_typed_values_not_strings
    widget = Widget.create!(title: 'a', featured: '1', views: '42', price: '9.5')
    reloaded = Widget.find(widget.id)
    assert_equal true, reloaded.featured
    assert_kind_of Integer, reloaded.views
    assert_equal 42, reloaded.views
    assert_kind_of Float, reloaded.price
  end

  def test_getter_defensively_casts_a_legacy_raw_value_never_written_through_the_setter
    id = @store.insert(:widgets, 'title' => 'legacy', 'featured' => '1', 'views' => '3')
    legacy = Widget.find(id)
    assert_equal true, legacy.featured
    assert_equal 3, legacy.views
  end

  def test_datetime_attribute_parses_an_iso8601_string
    widget = Widget.new(title: 'a', published_at: '2026-02-01T12:00:00Z')
    assert_kind_of Time, widget.published_at
    assert_equal 2026, widget.published_at.year
  end

  def test_invalid_input_raises_invalid_cast_instead_of_saving_garbage
    assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Widget.new(title: 'a', views: 'not-a-number') }
  end

  def test_serializable_hash_reflects_the_cast_type_not_the_raw_string
    widget = Widget.create!(title: 'a', featured: '1', views: '42')
    payload = JSON.parse(widget.to_json)
    assert_equal true, payload['featured']
    assert_equal 42, payload['views']
  end

  def test_subclass_inherits_the_parent_classes_declared_attributes
    Object.const_set(:Gadget, Class.new(Facet::Orm::Model) do
      table_name :widgets
      attribute :featured, :boolean, default: false
    end)
    Object.const_set(:SpecialGadget, Class.new(Gadget) do
      table_name :widgets
      attribute :views, :integer, default: 9
    end)
    SpecialGadget.store = @store

    assert_equal %i[boolean integer].sort_by(&:to_s), [SpecialGadget.attribute_types['featured'],
                                                         SpecialGadget.attribute_types['views']].sort_by(&:to_s)
    special = SpecialGadget.new(title: 'a')
    assert_equal false, special.featured, 'inherited attribute default was dropped by the subclass'
    assert_equal 9, special.views
  end
end
