require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'facet'

class CliDbSubprocessTest < Minitest::Test
  BIN_FACET = File.expand_path('../bin/facet', __dir__)

  def setup
    @workdir = Dir.mktmpdir('facet-cli-db-subprocess')
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
    write_migration(version, 'CreateWidgetsForCliDbSubprocessTest', <<~RUBY)
      def up
        create_table :widgets_for_cli_db_subprocess_test do |t|
          t.string :name
        end
      end

      def down
        drop_table :widgets_for_cli_db_subprocess_test
      end
    RUBY
  end

  def gadgets_migration(version = '20260101000002')
    write_migration(version, 'CreateGadgetsForCliDbSubprocessTest', <<~RUBY)
      def up
        create_table :gadgets_for_cli_db_subprocess_test do |t|
          t.string :label
        end
      end

      def down
        drop_table :gadgets_for_cli_db_subprocess_test
      end
    RUBY
  end

  def run_facet(*args)
    Open3.capture3(RbConfig.ruby, BIN_FACET, *args, chdir: @workdir)
  end

  def store
    Facet::Orm::Store.new(File.join(@workdir, 'db', 'test.pstore'))
  end

  def test_db_migrate_as_a_real_child_process_applies_pending_migrations
    widgets_migration

    stdout, stderr, status = run_facet('db:migrate', '--database=db/test.pstore')

    assert status.success?, "expected success, got #{status.exitstatus}, stderr: #{stderr}"
    assert_includes stdout, 'migrated 20260101000001'
    assert_empty stderr
    assert store.table_exists?(:widgets_for_cli_db_subprocess_test)
  end

  def test_db_migrate_as_a_real_child_process_with_nothing_pending
    widgets_migration
    run_facet('db:migrate', '--database=db/test.pstore')

    stdout, _stderr, status = run_facet('db:migrate', '--database=db/test.pstore')

    assert status.success?
    assert_includes stdout, 'no pending migrations'
  end

  def test_db_rollback_as_a_real_child_process_reverts_the_latest_migration
    widgets_migration
    gadgets_migration
    run_facet('db:migrate', '--database=db/test.pstore')
    assert store.table_exists?(:gadgets_for_cli_db_subprocess_test)

    stdout, _stderr, status = run_facet('db:rollback', '--database=db/test.pstore')

    assert status.success?
    assert_includes stdout, 'rolled back 20260101000002'
    refute store.table_exists?(:gadgets_for_cli_db_subprocess_test)
    assert store.table_exists?(:widgets_for_cli_db_subprocess_test)
  end

  def test_db_status_as_a_real_child_process_lists_applied_and_pending
    widgets_migration
    gadgets_migration
    run_facet('db:migrate', '--database=db/test.pstore')
    run_facet('db:rollback', '--database=db/test.pstore')

    stdout, _stderr, status = run_facet('db:status', '--database=db/test.pstore')

    assert status.success?
    assert_match(/up\s+20260101000001\s+create_widgets_for_cli_db_subprocess_test/, stdout)
    assert_match(/down\s+20260101000002\s+create_gadgets_for_cli_db_subprocess_test/, stdout)
  end

  def test_unknown_flag_exits_non_zero_with_an_error_on_stderr_not_stdout
    stdout, stderr, status = run_facet('db:migrate', '--bogus=1')

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/error:/, stderr)
    assert_empty stdout
  end

  def test_unknown_command_exits_non_zero_with_an_error
    _stdout, stderr, status = run_facet('db:frobnicate')

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/unknown command/, stderr)
  end
end
