require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'prism'

# test_cli_db.rb exercises Prism::Cli#db_migrate/#db_rollback/#db_status
# in-process (a bare Ruby method call against an already-loaded library) -
# useful, but it never proves the *executable* works: it does not touch
# `bin/prism`'s shebang, its $LOAD_PATH setup, ARGV parsing off a real
# argv, or a real process exit code. This file spawns `bin/prism` as an
# actual child process (Open3.capture3, a fresh `ruby` interpreter,
# nothing shared with the test's own Ruby VM beyond the filesystem) so a
# regression in any of that - e.g. a typo in bin/prism's require, a
# load-path assumption that only happens to hold when required from
# test/ - would fail here even though test_cli_db.rb stayed green.
class CliDbSubprocessTest < Minitest::Test
  BIN_PRISM = File.expand_path('../bin/prism', __dir__)

  def setup
    @workdir = Dir.mktmpdir('prism-cli-db-subprocess')
    FileUtils.mkdir_p(File.join(@workdir, 'db', 'migrate'))
  end

  def teardown
    FileUtils.remove_entry(@workdir)
  end

  def write_migration(version, class_name, body)
    path = File.join(@workdir, 'db', 'migrate', "#{version}_#{Prism::Inflector.underscore(class_name)}.rb")
    File.write(path, <<~RUBY)
      class #{class_name} < Prism::Orm::Migration
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

  # Runs `bin/prism <args>` as a real child process, chdir'd into the
  # scratch workdir the way a user's own shell would be when running
  # `prism db:migrate` inside their app directory - `Cli.new` defaults its
  # root to `Dir.pwd`, so this is the only way to exercise that default
  # rather than the explicit root test_cli_db.rb passes to `Cli.new`.
  def run_prism(*args)
    Open3.capture3(RbConfig.ruby, BIN_PRISM, *args, chdir: @workdir)
  end

  def store
    Prism::Orm::Store.new(File.join(@workdir, 'db', 'test.pstore'))
  end

  def test_db_migrate_as_a_real_child_process_applies_pending_migrations
    widgets_migration

    stdout, stderr, status = run_prism('db:migrate', '--database=db/test.pstore')

    assert status.success?, "expected success, got #{status.exitstatus}, stderr: #{stderr}"
    assert_includes stdout, 'migrated 20260101000001'
    assert_empty stderr
    assert store.table_exists?(:widgets_for_cli_db_subprocess_test)
  end

  def test_db_migrate_as_a_real_child_process_with_nothing_pending
    widgets_migration
    run_prism('db:migrate', '--database=db/test.pstore')

    stdout, _stderr, status = run_prism('db:migrate', '--database=db/test.pstore')

    assert status.success?
    assert_includes stdout, 'no pending migrations'
  end

  def test_db_rollback_as_a_real_child_process_reverts_the_latest_migration
    widgets_migration
    gadgets_migration
    run_prism('db:migrate', '--database=db/test.pstore')
    assert store.table_exists?(:gadgets_for_cli_db_subprocess_test)

    stdout, _stderr, status = run_prism('db:rollback', '--database=db/test.pstore')

    assert status.success?
    assert_includes stdout, 'rolled back 20260101000002'
    refute store.table_exists?(:gadgets_for_cli_db_subprocess_test)
    assert store.table_exists?(:widgets_for_cli_db_subprocess_test)
  end

  def test_db_status_as_a_real_child_process_lists_applied_and_pending
    widgets_migration
    gadgets_migration
    run_prism('db:migrate', '--database=db/test.pstore')
    run_prism('db:rollback', '--database=db/test.pstore')

    stdout, _stderr, status = run_prism('db:status', '--database=db/test.pstore')

    assert status.success?
    assert_match(/up\s+20260101000001\s+create_widgets_for_cli_db_subprocess_test/, stdout)
    assert_match(/down\s+20260101000002\s+create_gadgets_for_cli_db_subprocess_test/, stdout)
  end

  # bin/prism's own UsageError->exit(1) handling (`rescue ...; warn ...;
  # exit 1`) only runs when invoked as a real process - calling
  # Cli#db_migrate directly, as test_cli_db.rb does, raises the exception
  # straight into the caller instead of going through that rescue at all,
  # so it cannot prove the process exits non-zero and prints to stderr.
  def test_unknown_flag_exits_non_zero_with_an_error_on_stderr_not_stdout
    stdout, stderr, status = run_prism('db:migrate', '--bogus=1')

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/error:/, stderr)
    assert_empty stdout
  end

  def test_unknown_command_exits_non_zero_with_an_error
    _stdout, stderr, status = run_prism('db:frobnicate')

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/unknown command/, stderr)
  end
end
