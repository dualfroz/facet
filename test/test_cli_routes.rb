require 'minitest/autorun'
require 'facet'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class CliRoutesTest < Minitest::Test
  def setup
    @workdir = Dir.mktmpdir('facet-cli-routes')
    @cli = Facet::Cli.new(@workdir)
  end

  def teardown
    FileUtils.remove_entry(@workdir)
    %i[RoutesTestApp RoutesTestOtherApp].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end

  def write_fixture(filename, content)
    path = File.join(@workdir, filename)
    File.write(path, content)
    filename
  end

  def run_routes(extra_args = [])
    out = StringIO.new
    @cli.routes(extra_args, out: out)
    out.string
  end

  def test_lists_named_and_unnamed_routes_with_verb_path_and_target
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        root to: 'posts#index'
        get '/posts/:id', to: 'posts#show', as: :post
        post '/posts', to: 'posts#create'
      end
    RUBY

    output = run_routes(['--require=app.rb'])

    assert_match(/GET\s+\/\s+posts#index\s+root_path/, output)
    assert_match(/GET\s+\/posts\/:id\s+posts#show\s+post_path/, output)
    assert_match(/POST\s+\/posts\s+posts#create\s*$/, output)
  end

  def test_resources_expands_into_seven_named_routes
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        resources :posts
      end
    RUBY

    output = run_routes(['--require=app.rb'])
    lines = output.lines.map(&:strip)

    assert_equal 8, lines.count { |line| line.include?('posts#') }
    assert(lines.any? { |line| line.start_with?('GET') && line.include?('posts_path') && line.include?('posts#index') })
    assert(lines.any? { |line| line.include?('new_post_path') && line.include?('posts#new') })
    assert(lines.any? { |line| line.include?('edit_post_path') && line.include?('posts#edit') })
  end

  def test_inline_block_route_is_labeled_block_instead_of_controller_action
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        get('/ping') { |req, res| res.write('pong') }
      end
    RUBY

    output = run_routes(['--require=app.rb'])
    assert_match(%r{GET\s+/ping\s+\(block\)}, output)
  end

  def test_mounted_apps_are_listed_separately_from_regular_routes
    write_fixture('app.rb', <<~'RUBY')
      class RoutesTestApp < Facet::Application
        root to: 'posts#index'
        mount '/admin', ->(env) { [200, {}, ['admin']] }
      end
    RUBY

    output = run_routes(['--require=app.rb'])
    assert_includes output, 'MOUNT  /admin ->'
    refute_match(/MOUNT.*posts#index/, output)
  end

  def test_raises_when_no_application_subclass_is_loaded
    assert_raises(Facet::Cli::UsageError) { run_routes([]) }
  end

  def test_raises_and_names_both_classes_when_multiple_applications_are_loaded_without_dash_dash_app
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        root to: 'posts#index'
      end
      class RoutesTestOtherApp < Facet::Application
        root to: 'comments#index'
      end
    RUBY

    error = assert_raises(Facet::Cli::UsageError) { run_routes(['--require=app.rb']) }
    assert_includes error.message, 'RoutesTestApp'
    assert_includes error.message, 'RoutesTestOtherApp'
    assert_includes error.message, '--app='
  end

  def test_dash_dash_app_disambiguates_between_multiple_loaded_applications
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        root to: 'posts#index'
      end
      class RoutesTestOtherApp < Facet::Application
        root to: 'comments#index'
      end
    RUBY

    output = run_routes(['--require=app.rb', '--app=RoutesTestOtherApp'])
    assert_includes output, 'comments#index'
    refute_includes output, 'posts#index'
  end

  def test_unknown_option_raises_usage_error
    assert_raises(Facet::Cli::UsageError) { @cli.routes(['--bogus'], out: StringIO.new) }
  end

  def test_run_dispatches_routes_command
    write_fixture('app.rb', <<~RUBY)
      class RoutesTestApp < Facet::Application
        root to: 'posts#index'
      end
    RUBY

    out = StringIO.new
    original_stdout = $stdout
    $stdout = out
    begin
      @cli.run(['routes', "--require=#{File.join(@workdir, 'app.rb')}"])
    ensure
      $stdout = original_stdout
    end
    assert_includes out.string, 'posts#index'
  end
end
