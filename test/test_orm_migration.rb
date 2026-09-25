require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmMigrationTest < Minitest::Test
  def setup
    @store_dir = Dir.mktmpdir('facet-migration-store')
    @migrations_dir = Dir.mktmpdir('facet-migration-files')
    @store = Facet::Orm::Store.new(File.join(@store_dir, 'test.pstore'))
  end

  def teardown
    FileUtils.remove_entry(@store_dir)
    FileUtils.remove_entry(@migrations_dir)
  end

  def write_migration(version, class_name, body)
    path = File.join(@migrations_dir, "#{version}_#{Facet::Inflector.underscore(class_name)}.rb")
    File.write(path, <<~RUBY)
      class #{class_name} < Facet::Orm::Migration
        #{body}
      end
    RUBY
    path
  end

  def test_migrate_creates_table
    write_migration('20260101000001', 'CreateWidgetsForMigrationTest', <<~RUBY)
      def up
        create_table :widgets_for_migration_test do |t|
          t.string :name
        end
      end

      def down
        drop_table :widgets_for_migration_test
      end
    RUBY

    migrator = Facet::Orm::Migrator.new(@store, @migrations_dir)
    applied = migrator.migrate!

    assert_equal ['20260101000001'], applied
    assert @store.table_exists?(:widgets_for_migration_test)
    assert_equal ['20260101000001'], @store.applied_migrations
  end

  def test_pending_excludes_applied_migrations
    write_migration('20260101000002', 'CreateGizmosForMigrationTest', <<~RUBY)
      def up
        create_table(:gizmos_for_migration_test) { |t| t.string :name }
      end

      def down
        drop_table :gizmos_for_migration_test
      end
    RUBY

    migrator = Facet::Orm::Migrator.new(@store, @migrations_dir)
    assert_equal 1, migrator.pending.size
    migrator.migrate!
    assert_empty migrator.pending
  end

  def test_rollback_runs_down_and_forgets_version
    write_migration('20260101000003', 'CreateSprocketsForMigrationTest', <<~RUBY)
      def up
        create_table(:sprockets_for_migration_test) { |t| t.string :name }
      end

      def down
        drop_table :sprockets_for_migration_test
      end
    RUBY

    migrator = Facet::Orm::Migrator.new(@store, @migrations_dir)
    migrator.migrate!
    assert @store.table_exists?(:sprockets_for_migration_test)

    rolled_back = migrator.rollback!
    assert_equal ['20260101000003'], rolled_back
    refute @store.table_exists?(:sprockets_for_migration_test)
    assert_empty @store.applied_migrations
  end

  def test_status_reports_applied_and_pending_migrations_in_order
    write_migration('20260101000004', 'CreateCogsForMigrationTest', <<~RUBY)
      def up
        create_table(:cogs_for_migration_test) { |t| t.string :name }
      end

      def down
        drop_table :cogs_for_migration_test
      end
    RUBY
    write_migration('20260101000005', 'CreateBoltsForMigrationTest', <<~RUBY)
      def up
        create_table(:bolts_for_migration_test) { |t| t.string :name }
      end

      def down
        drop_table :bolts_for_migration_test
      end
    RUBY

    migrator = Facet::Orm::Migrator.new(@store, @migrations_dir)
    migrator.migrate!
    migrator.rollback!

    status = migrator.status
    versions_and_state = status.map { |entry, applied| [entry.version, applied] }
    assert_includes versions_and_state, ['20260101000004', true]
    assert_includes versions_and_state, ['20260101000005', false]
    assert_equal status.map { |entry, _| entry.version }, status.map { |entry, _| entry.version }.sort
  end

  def test_rollback_multiple_steps_reverts_in_reverse_order
    write_migration('20260101000020', 'FirstMultiRollbackTest', <<~RUBY)
      def up
        create_table(:multi_rollback_a) { |t| t.string :name }
      end

      def down
        drop_table :multi_rollback_a
      end
    RUBY
    write_migration('20260101000021', 'SecondMultiRollbackTest', <<~RUBY)
      def up
        create_table(:multi_rollback_b) { |t| t.string :name }
      end

      def down
        drop_table :multi_rollback_b
      end
    RUBY

    migrator = Facet::Orm::Migrator.new(@store, @migrations_dir)
    migrator.migrate!
    assert @store.table_exists?(:multi_rollback_a)
    assert @store.table_exists?(:multi_rollback_b)

    reverted = migrator.rollback!(2)
    assert_equal ['20260101000021', '20260101000020'], reverted
    refute @store.table_exists?(:multi_rollback_a)
    refute @store.table_exists?(:multi_rollback_b)
    assert_empty @store.applied_migrations
  end

  def test_add_and_remove_column_in_migration
    write_migration('20260101000004', 'CreateThingiesForMigrationTest', <<~RUBY)
      def up
        create_table(:thingies_for_migration_test) { |t| t.string :name }
        add_column :thingies_for_migration_test, :active
      end

      def down
        remove_column :thingies_for_migration_test, :active
        drop_table :thingies_for_migration_test
      end
    RUBY

    Facet::Orm::Migrator.new(@store, @migrations_dir).migrate!
    assert_includes @store.columns(:thingies_for_migration_test), 'active'
  end

  def test_migrations_run_in_version_order
    write_migration('20260101000010', 'SecondForOrderingTest', <<~RUBY)
      def up
        store.insert(:ordering_test_log, step: 'second')
      end

      def down; end
    RUBY
    write_migration('20260101000005', 'FirstForOrderingTest', <<~RUBY)
      def up
        create_table(:ordering_test_log) { |t| t.string :step }
        store.insert(:ordering_test_log, step: 'first')
      end

      def down; end
    RUBY

    Facet::Orm::Migrator.new(@store, @migrations_dir).migrate!
    steps = @store.all(:ordering_test_log).map { |row| row['step'] }
    assert_equal %w[first second], steps
  end
end
