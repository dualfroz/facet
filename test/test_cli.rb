require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class CliTest < Minitest::Test
  def setup
    @workdir = Dir.mktmpdir('prism-cli')
    @cli = Prism::Cli.new(@workdir)
  end

  def teardown
    FileUtils.remove_entry(@workdir)
  end

  def test_new_app_scaffolds_expected_files
    app_dir = @cli.new_app('blog')
    assert File.directory?(File.join(app_dir, 'app', 'controllers'))
    assert File.directory?(File.join(app_dir, 'app', 'models'))
    assert File.directory?(File.join(app_dir, 'db', 'migrate'))
    assert File.file?(File.join(app_dir, 'app.rb'))
    assert File.file?(File.join(app_dir, 'config.ru'))
    assert File.file?(File.join(app_dir, 'app', 'views', 'layouts', 'application.erb'))
    assert File.executable?(File.join(app_dir, 'bin', 'server'))
  end

  def test_new_app_boot_file_references_app_class
    app_dir = @cli.new_app('blog')
    content = File.read(File.join(app_dir, 'app.rb'))
    assert_includes content, 'class Blog < Prism::Application'
  end

  def test_new_app_refuses_to_overwrite_existing_directory
    @cli.new_app('blog')
    assert_raises(Prism::Cli::UsageError) { @cli.new_app('blog') }
  end

  def test_generate_migration_for_create_table
    path = @cli.generate_migration('create_posts', ['title:string', 'body:text'])
    content = File.read(path)
    assert_includes content, 'class CreatePosts < Prism::Orm::Migration'
    assert_includes content, 'create_table :posts do |t|'
    assert_includes content, 't.string :title'
    assert_includes content, 't.text :body'
    assert_includes content, 't.timestamps'
    assert_includes content, 'drop_table :posts'
  end

  def test_generate_migration_filename_has_version_prefix
    path = @cli.generate_migration('create_posts', [])
    assert_match(/\A\d{14}_create_posts\.rb\z/, File.basename(path))
  end

  def test_generate_migration_avoids_version_collisions_within_the_same_second
    first = @cli.generate_migration('create_posts', [])
    second = @cli.generate_migration('create_comments', [])
    first_version = File.basename(first).split('_', 2).first
    second_version = File.basename(second).split('_', 2).first
    refute_equal first_version, second_version
  end

  def test_generated_migration_actually_runs
    path = @cli.generate_migration('create_widgets', ['name:string'])
    store = Prism::Orm::Store.new(File.join(@workdir, 'test.pstore'))
    Prism::Orm::Migrator.new(store, File.dirname(path)).migrate!
    assert store.table_exists?(:widgets)
    assert_includes store.columns(:widgets), 'name'
  end

  def test_generate_model_creates_model_and_migration
    model_path, migration_path = @cli.generate_model('post', ['title:string'])
    assert_includes File.read(model_path), 'class Post < Prism::Orm::Model'
    assert_includes File.read(migration_path), 'create_table :posts do |t|'
  end

  def test_bin_prism_new_via_subprocess
    lib_dir = File.expand_path('../lib', __dir__)
    bin_path = File.expand_path('../bin/prism', __dir__)
    ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
    output = IO.popen([ruby, "-I#{lib_dir}", bin_path, 'new', 'shop'], chdir: @workdir, err: [:child, :out], &:read)
    status = $?.exitstatus
    assert_equal 0, status, output
    assert File.file?(File.join(@workdir, 'shop', 'app.rb'))
  end

  def test_bin_prism_reports_usage_error_and_nonzero_exit
    lib_dir = File.expand_path('../lib', __dir__)
    bin_path = File.expand_path('../bin/prism', __dir__)
    ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
    output = IO.popen([ruby, "-I#{lib_dir}", bin_path, 'bogus'], chdir: @workdir, err: [:child, :out], &:read)
    status = $?.exitstatus
    refute_equal 0, status
    assert_includes output, 'unknown command'
  end
end
