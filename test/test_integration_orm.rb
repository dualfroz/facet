require 'minitest/autorun'
require 'facet'
require 'net/http'
require 'tmpdir'
require 'fileutils'

class IntegrationOrmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-e2e-orm')
    @db_path = File.join(@dir, 'blog.pstore')
    @views_dir = File.join(@dir, 'views', 'e2e_posts')
    FileUtils.mkdir_p(@views_dir)
    File.write(File.join(@views_dir, 'index.erb'), <<~ERB)
      <ul class="posts">
      <% posts.each do |post| %>
      <li><%= post.title %>: <%= post.body %></li>
      <% end %>
      </ul>
    ERB

    Facet::Orm.connect(@db_path)
    Facet::Orm.store.create_table(:e2e_posts, %w[id title body created_at updated_at])

    views_dir = File.dirname(@views_dir)
    post_class = Class.new(Facet::Orm::Model) do
      table_name :e2e_posts
      validates :title, presence: true
    end
    Object.const_set(:E2ePost, post_class)

    controller_class = Class.new(Facet::Controller) do
      views_root views_dir

      define_method(:index) { render(:index, locals: { posts: E2ePost.order(:id) }) }
      define_method(:create) do
        post = E2ePost.create(title: params['title'], body: params['body'])
        json({ id: post.id }, 201)
      end
    end
    Object.const_set(:E2ePostsController, controller_class)

    app_class = Class.new(Facet::Application) do
      get '/posts', to: 'e2e_posts#index'
      post '/posts', to: 'e2e_posts#create'
    end
    Object.const_set(:E2eBlogApp, app_class)
  end

  def teardown
    @server&.stop
    %i[E2ePost E2ePostsController E2eBlogApp].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    FileUtils.remove_entry(@dir)
  end

  def test_post_then_get_round_trip_and_survives_a_process_restart
    @server = Facet::Server.new(E2eBlogApp, port: 0).start
    port = @server.port

    create_response = Net::HTTP.start('127.0.0.1', port) do |http|
      http.post('/posts', URI.encode_www_form(title: 'Hello Facet', body: 'first real post'),
                 'Content-Type' => 'application/x-www-form-urlencoded')
    end
    assert_equal '201', create_response.code
    created_id = JSON.parse(create_response.body)['id']
    refute_nil created_id

    listing_response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/posts"))
    assert_equal '200', listing_response.code
    assert_includes listing_response.body, 'Hello Facet: first real post'

    @server.stop
    @server = nil

    Facet::Orm.connect(@db_path)
    restarted_server = Facet::Server.new(E2eBlogApp, port: 0).start
    begin
      restarted_response = Net::HTTP.get_response(URI("http://127.0.0.1:#{restarted_server.port}/posts"))
      assert_equal '200', restarted_response.code
      assert_includes restarted_response.body, 'Hello Facet: first real post',
                       'data inserted before the restart must still render after reconnecting to the store file'
    ensure
      restarted_server.stop
    end
  end
end
