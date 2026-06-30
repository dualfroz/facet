require 'minitest/autorun'
require 'prism'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class CliDbSeedTestWidget < Prism::Orm::Model
  table_name 'cli_db_seed_test_widgets'
end

class CliDbSeedTest < Minitest::Test
  def setup
    @workdir = Dir.mktmpdir('prism-cli-db-seed')
    @cli = Prism::Cli.new(@workdir)
    @database = File.join(@workdir, 'db', 'test.pstore')
    FileUtils.mkdir_p(File.join(@workdir, 'db'))
    Prism::Orm.connect(@database)
    store.create_table('cli_db_seed_test_widgets', %w[id name])
  end

  def teardown
    FileUtils.remove_entry(@workdir)
    Object.send(:remove_const, :CliDbSeedTestRequiredApp) if Object.const_defined?(:CliDbSeedTestRequiredApp)
  end

  def store
    Prism::Orm::Store.new(@database)
  end

  def write_seeds(content, filename = 'db/seeds.rb')
    path = File.join(@workdir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    filename
  end

  def test_db_seed_runs_the_seeds_file_against_the_already_loaded_environment
    write_seeds("CliDbSeedTestWidget.create!(name: 'sprocket')\n")

    out = StringIO.new
    result = @cli.db_seed([], out: out)

    assert_equal true, result
    assert_includes out.string, 'seeded from db/seeds.rb'
    assert_equal ['sprocket'], store.all('cli_db_seed_test_widgets').map { |row| row['name'] }
  end

  def test_db_seed_with_no_seeds_file_reports_that_instead_of_erroring
    out = StringIO.new
    result = @cli.db_seed([], out: out)

    assert_equal false, result
    assert_includes out.string, 'no seeds file at db/seeds.rb'
  end

  def test_db_seed_dispatches_through_run
    write_seeds("CliDbSeedTestWidget.create!(name: 'via-run')\n")

    capture_io { @cli.run(['db:seed']) }

    assert_equal ['via-run'], store.all('cli_db_seed_test_widgets').map { |row| row['name'] }
  end

  def test_db_seed_honors_a_custom_file_path
    write_seeds("CliDbSeedTestWidget.create!(name: 'custom')\n", 'db/custom_seeds.rb')

    out = StringIO.new
    result = @cli.db_seed(['--file=db/custom_seeds.rb'], out: out)

    assert_equal true, result
    assert_includes out.string, 'seeded from db/custom_seeds.rb'
    assert_equal ['custom'], store.all('cli_db_seed_test_widgets').map { |row| row['name'] }
  end

  def test_db_seed_requires_the_environment_before_running_the_seeds_file
    File.write(File.join(@workdir, 'app.rb'), <<~RUBY)
      class CliDbSeedTestRequiredApp
        def self.slogan
          'from --require'
        end
      end
    RUBY
    write_seeds("CliDbSeedTestWidget.create!(name: CliDbSeedTestRequiredApp.slogan)\n")

    @cli.db_seed(['--require=app.rb'], out: StringIO.new)

    assert_equal ['from --require'], store.all('cli_db_seed_test_widgets').map { |row| row['name'] }
  end

  # `load`, not `require`: a seeds file is a sequence of side effects, not a
  # class/module definition with meaningful "already loaded" state, so a
  # second db:seed run must re-execute it rather than silently no-op the way
  # `require` would once that exact path had already been loaded once.
  def test_db_seed_reruns_the_file_on_every_call_instead_of_requiring_it_once
    write_seeds("CliDbSeedTestWidget.create!(name: 'again')\n")

    @cli.db_seed([], out: StringIO.new)
    @cli.db_seed([], out: StringIO.new)

    assert_equal %w[again again], store.all('cli_db_seed_test_widgets').map { |row| row['name'] }
  end

  def test_db_seed_rejects_unknown_options
    assert_raises(Prism::Cli::UsageError) { @cli.db_seed(['--bogus=1']) }
  end
end
