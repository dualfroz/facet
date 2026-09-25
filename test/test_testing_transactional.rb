require 'minitest/autorun'
require 'facet'
require 'tmpdir'

module TransactionalFixtures
  DIR = Dir.mktmpdir('facet-transactional-tests')
  STORE = Facet::Orm::Store.new(File.join(DIR, 'test.pstore'))
  STORE.create_table(:widgets, %w[id name])

  class Widget < Facet::Orm::Model
    self.store = STORE
    table_name :widgets

    class << self
      attr_accessor :rollback_count
    end
    self.rollback_count = 0

    after_rollback { self.class.rollback_count += 1 }
  end

  OTHER_STORE = Facet::Orm::Store.new(File.join(DIR, 'other.pstore'))
  OTHER_STORE.create_table(:gadgets, %w[id name])

  class Gadget < Facet::Orm::Model
    self.store = OTHER_STORE
    table_name :gadgets
  end
end

class TransactionalVictimTest < Minitest::Test
  include Facet::Testing::IntegrationTest
  use_transactional_tests(store: TransactionalFixtures::STORE)

  def test_creates_exactly_one_widget
    TransactionalFixtures::Widget.create!(name: 'gizmo')
    assert_equal 1, TransactionalFixtures::Widget.count
  end
end

class MultiStoreVictimTest < Minitest::Test
  include Facet::Testing::IntegrationTest
  use_transactional_tests(stores: [TransactionalFixtures::STORE, TransactionalFixtures::OTHER_STORE])

  def test_creates_a_widget_and_a_gadget
    TransactionalFixtures::Widget.create!(name: 'gizmo')
    TransactionalFixtures::Gadget.create!(name: 'sprocket')
    assert_equal 1, TransactionalFixtures::Widget.count
    assert_equal 1, TransactionalFixtures::Gadget.count
  end
end

class PlainIntegrationSampleTest < Minitest::Test
  include Facet::Testing::IntegrationTest

  def test_noop
    assert true
  end
end

class TestTestingTransactional < Minitest::Test
  Widget = TransactionalFixtures::Widget

  def test_writes_are_rolled_back_once_the_test_finishes
    assert_equal 0, Widget.count
    result = TransactionalVictimTest.new(:test_creates_exactly_one_widget).run
    assert result.passed?, result.failures.map(&:message).join("\n")
    assert_equal 0, Widget.count, 'the widget created inside the test should not survive it'
  end

  def test_running_the_same_test_twice_never_sees_a_leftover_row
    result1 = TransactionalVictimTest.new(:test_creates_exactly_one_widget).run
    result2 = TransactionalVictimTest.new(:test_creates_exactly_one_widget).run
    assert result1.passed?, result1.failures.map(&:message).join("\n")
    assert result2.passed?, result2.failures.map(&:message).join("\n")
    assert_equal 0, Widget.count
  end

  def test_after_rollback_callbacks_fire_when_the_transaction_unwinds
    before = Widget.rollback_count
    result = TransactionalVictimTest.new(:test_creates_exactly_one_widget).run
    assert result.passed?, result.failures.map(&:message).join("\n")
    assert_equal before + 1, Widget.rollback_count
  end

  def test_classes_that_never_opt_in_are_unaffected
    result = PlainIntegrationSampleTest.new(:test_noop).run
    assert result.passed?, result.failures.map(&:message).join("\n")
  end

  def test_transactional_tests_store_is_inherited_by_subclasses
    subclass = Class.new(TransactionalVictimTest)
    assert_equal TransactionalFixtures::STORE, subclass.transactional_tests_store
  end

  def test_default_store_option_resolves_to_facet_orm_store_lazily
    klass = Class.new(Minitest::Test) do
      include Facet::Testing::IntegrationTest
      use_transactional_tests
    end
    assert_equal :default, klass.transactional_tests_store
    assert_equal [:default], klass.transactional_tests_stores
  end

  def test_multiple_stores_all_roll_back_after_the_test_finishes
    assert_equal 0, TransactionalFixtures::Widget.count
    assert_equal 0, TransactionalFixtures::Gadget.count

    result = MultiStoreVictimTest.new(:test_creates_a_widget_and_a_gadget).run
    assert result.passed?, result.failures.map(&:message).join("\n")

    assert_equal 0, TransactionalFixtures::Widget.count,
                 'the widget in the FIRST configured store must not survive the test'
    assert_equal 0, TransactionalFixtures::Gadget.count,
                 'the gadget in the SECOND, independent store must not survive the test either'
  end

  def test_stores_option_is_exposed_as_an_array_and_store_returns_its_first_element
    assert_equal [TransactionalFixtures::STORE, TransactionalFixtures::OTHER_STORE],
                 MultiStoreVictimTest.transactional_tests_stores
    assert_equal TransactionalFixtures::STORE, MultiStoreVictimTest.transactional_tests_store
  end
end
