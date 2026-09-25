require 'minitest/autorun'
require 'facet'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class CliDbTest < Minitest::Test
  def setup
    @workdir = Dir.mktmpdir('facet-cli-db')
    @cli = Facet::Cli.new(@workdir)
    @database = 'db/test.pstore'
    FileUtils.mkdir_p(File.join(@workdir, 'db', 'migrate'))
  end

  def teardown
    FileUtils.remove_entry(@workdir)
  end

  def write_migration(version, class_name, body)
    path = File.join(@workdir, 'db', 'migrate', "#{version}_#{Facet::Inflector.underscore(class_name)}.rb")
    File.write(path, <<~RUBY)
      class #{class_name} < Facet::Orm::Migration
        #{body}
      end
    RUBY
    path
  end

  def widgets_migration(version = '20260101000001')
    write_migration(version, 'CreateWidgetsForCliDbTest', <<~RUBY)
      def up
        create_table :widgets_for_cli_db_test do |t|
          t.string :name
        end
      end

      def down
        drop_table :widgets_for_cli_db_test
      end
    RUBY
  end

  def gadgets_migration(version = '20260101000002')
    write_migration(version, 'CreateGadgetsForCliDbTest', <<~RUBY)
      def up
        create_table :gadgets_for_cli_db_test do |t|
          t.string :label
        end
      end

      def down
        drop_table :gadgets_for_cli_db_test
      end
    RUBY
  end

  def store
    Facet::Orm::Store.new(File.join(@workdir, @database))
  end

  def test_db_migrate_applies_pending_migrations_and_reports_them
    widgets_migration
    out = StringIO.new
    applied = @cli.db_migrate(["--database=#{@database}"], out: out)

    assert_equal ['20260101000001'], applied
    assert_includes out.string, 'migrated 20260101000001'
    assert store.table_exists?(:widgets_for_cli_db_test)
  end

  def test_db_migrate_with_nothing_pending_reports_that_instead_of_erroring
    widgets_migration
    @cli.db_migrate(["--database=#{@database}"], out: StringIO.new)

    out = StringIO.new
    applied = @cli.db_migrate(["--database=#{@database}"], out: out)

    assert_empty applied
    assert_includes out.string, 'no pending migrations'
  end

  def test_db_migrate_dispatches_through_run
    widgets_migration
    capture_io { @cli.run(['db:migrate', "--database=#{@database}"]) }
    assert store.table_exists?(:widgets_for_cli_db_test)
  end

  def test_db_rollback_defaults_to_one_step
    widgets_migration
    gadgets_migration
    @cli.db_migrate(["--database=#{@database}"], out: StringIO.new)
    assert store.table_exists?(:gadgets_for_cli_db_test)

    out = StringIO.new
    reverted = @cli.db_rollback(["--database=#{@database}"], out: out)

    assert_equal ['20260101000002'], reverted
    assert_includes out.string, 'rolled back 20260101000002'
    refute store.table_exists?(:gadgets_for_cli_db_test)
    assert store.table_exists?(:widgets_for_cli_db_test), 'earlier migration must survive a single-step rollback'
  end

  def test_db_rollback_honors_explicit_step_count
    widgets_migration
    gadgets_migration
    @cli.db_migrate(["--database=#{@database}"], out: StringIO.new)

    reverted = @cli.db_rollback(["--database=#{@database}", '--step=2'], out: StringIO.new)

    assert_equal ['20260101000002', '20260101000001'], reverted
    refute store.table_exists?(:gadgets_for_cli_db_test)
    refute store.table_exists?(:widgets_for_cli_db_test)
  end

  def test_db_rollback_with_nothing_applied_reports_that_instead_of_erroring
    widgets_migration
    out = StringIO.new
    reverted = @cli.db_rollback(["--database=#{@database}"], out: out)

    assert_empty reverted
    assert_includes out.string, 'nothing to roll back'
  end

  def test_db_status_marks_applied_migrations_up_and_the_rest_down
    widgets_migration
    gadgets_migration
    @cli.db_migrate(["--database=#{@database}"], out: StringIO.new)
    @cli.db_rollback(["--database=#{@database}"], out: StringIO.new)

    out = StringIO.new
    status = @cli.db_status(["--database=#{@database}"], out: out)

    assert_equal [['20260101000001', true], ['20260101000002', false]],
                 status.map { |entry, applied| [entry.version, applied] }
    assert_match(/up\s+20260101000001\s+create_widgets_for_cli_db_test/, out.string)
    assert_match(/down\s+20260101000002\s+create_gadgets_for_cli_db_test/, out.string)
  end

  def test_db_status_with_no_migration_files_prints_only_the_header
    out = StringIO.new
    status = @cli.db_status(["--database=#{@database}"], out: out)

    assert_empty status
    assert_equal "STATUS  VERSION  NAME\n", out.string
  end

  def test_db_commands_use_the_migrations_flag_to_find_a_custom_directory
    FileUtils.mkdir_p(File.join(@workdir, 'other_migrations'))
    File.write(File.join(@workdir, 'other_migrations', '20260101000003_create_thingies_for_cli_db_test.rb'), <<~RUBY)
      class CreateThingiesForCliDbTest < Facet::Orm::Migration
        def up
          create_table :thingies_for_cli_db_test do |t|
            t.string :name
          end
        end

        def down
          drop_table :thingies_for_cli_db_test
        end
      end
    RUBY

    applied = @cli.db_migrate(["--database=#{@database}", '--migrations=other_migrations'], out: StringIO.new)

    assert_equal ['20260101000003'], applied
    assert store.table_exists?(:thingies_for_cli_db_test)
  end

  def test_db_options_reject_unknown_flags
    assert_raises(Facet::Cli::UsageError) { @cli.db_migrate(['--bogus=1']) }
    assert_raises(Facet::Cli::UsageError) { @cli.db_rollback(['--bogus=1']) }
    assert_raises(Facet::Cli::UsageError) { @cli.db_status(['--bogus=1']) }
  end
end
