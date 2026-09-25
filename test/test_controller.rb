require 'minitest/autorun'
require 'facet'
require 'support'
require 'tmpdir'
require 'fileutils'

class ControllerTest < Minitest::Test
  include TestSupport

  def setup
    @views_dir = Dir.mktmpdir('facet-controller-views')
    write_views
    define_controller
    define_app
  end

  def teardown
    FileUtils.remove_entry(@views_dir)
    %i[PostsController PostsApp].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def write_views
    FileUtils.mkdir_p(File.join(@views_dir, 'posts'))
    FileUtils.mkdir_p(File.join(@views_dir, 'layouts'))
    File.write(File.join(@views_dir, 'layouts', 'application.erb'), <<~ERB)
      <!doctype html><html><body><%== content %></body></html>
    ERB
    File.write(File.join(@views_dir, 'posts', 'index.erb'), <<~ERB)
      <ul><% posts.each do |title| %><%== partial('post', locals: { title: title }) %><% end %></ul>
    ERB
    File.write(File.join(@views_dir, 'posts', '_post.erb'), '<li><%= title %></li>')
    File.write(File.join(@views_dir, 'posts', 'show.erb'), '<h1><%= id %></h1>')
  end

  def define_controller
    views_dir = @views_dir
    controller_class = Class.new(Facet::Controller) do
      layout :application
      views_root views_dir

      before_action :set_common, only: %i[index show]
      after_action :mark_served

      def self.served_log
        @served_log ||= []
      end

      def set_common
        @posts = ['first post', 'second post']
      end

      def index
        render(:index, locals: { posts: @posts })
      end

      def show
        render(:show, layout: nil, locals: { id: params['id'] })
      end

      def create
        halt(201, JSON.generate(created: params['title']))
      end

      def mark_served
        self.class.served_log << action_name
      end
    end
    Object.const_set(:PostsController, controller_class)
  end

  def define_app
    app_class = Class.new(Facet::Application) do
      get '/posts', to: 'posts#index', as: :posts
      get '/posts/:id', to: 'posts#show', as: :post
      post '/posts', to: 'posts#create'
    end
    Object.const_set(:PostsApp, app_class)
  end

  def call(method, path, **opts)
    PostsApp.call(env_for(method, path, **opts))
  end

  def test_index_renders_with_layout_and_partials
    _, _, body = call('GET', '/posts')
    html = body.join
    assert_includes html, '<!doctype html>'
    assert_includes html, '<li>first post</li>'
    assert_includes html, '<li>second post</li>'
  end

  def test_show_renders_action_template
    _, _, body = call('GET', '/posts/42')
    assert_equal '<h1>42</h1>', body.join
  end

  def test_before_action_runs_with_only_filter
    PostsController.served_log.clear
    call('GET', '/posts')
    call('GET', '/posts/1')
    call('POST', '/posts')
    assert_equal %w[index show create], PostsController.served_log
  end

  def test_create_action_uses_halt
    status, _, body = call('POST', '/posts', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: 'title=hello')
    assert_equal 201, status
    assert_equal 'hello', JSON.parse(body.join)['created']
  end

  def test_named_route_url_for
    status, _, body = call('GET', '/posts/9')
    assert_equal 200, status
    assert_equal PostsApp.router.path_to(:post, id: 9), '/posts/9'
  end
end
