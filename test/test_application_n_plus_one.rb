require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'stringio'
require 'support'

# Regression coverage for the real bug found while wiring raise_on_violation
# into examples/blog: Application#dispatch used to call
# Orm::NPlusOneDetector.report! AFTER the instrumented span's rescue reach had
# already closed, so a violation blew straight out of #dispatch (and, over a
# real socket, out of Server#serve too - server.rb only rescues EPIPE/
# ECONNRESET/IOError around @app.call, not StandardError) instead of getting
# the same 500 treatment every other uncaught exception in this app gets.
# These tests go through Application.call end-to-end (not
# NPlusOneDetector.report! directly, which test_orm_n_plus_one_detector.rb
# already covers in isolation) to prove the fix at the layer that matters.
class ApplicationNPlusOneTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('prism-app-n-plus-one')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])

    author_class = Class.new(Prism::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'NPlusOnePost', foreign_key: 'author_id'
    end
    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'NPlusOneAuthor', foreign_key: 'author_id'
    end
    [author_class, post_class].each { |klass| klass.store = @store }
    Object.const_set(:NPlusOneAuthor, author_class)
    Object.const_set(:NPlusOnePost, post_class)

    3.times do |i|
      author = NPlusOneAuthor.create!(name: "author#{i}")
      NPlusOnePost.create!(title: "post#{i}", author_id: author.id)
    end

    @io = StringIO.new
    author = NPlusOneAuthor
    app = Class.new(Prism::Application) do
      get('/n_plus_one') do
        author.all.to_a.each { |a| a.posts.to_a }
        'rendered'
      end
    end
    @app = app
  end

  def teardown
    Prism::Orm::NPlusOneDetector.disable!
    Prism::Orm::NPlusOneDetector.reset!
    FileUtils.remove_entry(@dir)
    %i[NPlusOneAuthor NPlusOnePost].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_log_only_mode_returns_a_normal_response_and_warns_to_io
    Prism::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io, raise_on_violation: false)

    status, _headers, body = @app.call(env_for('GET', '/n_plus_one'))

    assert_equal 200, status
    assert_equal 'rendered', body.join
    assert_match(/N\+1 query detected: NPlusOneAuthor#posts/, @io.string)
  end

  def test_raise_on_violation_turns_into_a_real_500_response_not_an_escaped_exception
    Prism::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io, raise_on_violation: true)

    status, headers, body = @app.call(env_for('GET', '/n_plus_one'))

    assert_equal 500, status
    assert_equal 'text/plain', headers['Content-Type']
    assert_equal 'Internal Server Error', body.join
    assert_match(/N\+1 query detected: NPlusOneAuthor#posts/, @io.string)
  end

  def test_raise_on_violation_below_threshold_still_returns_the_normal_response
    Prism::Orm::NPlusOneDetector.enable!(threshold: 10, io: @io, raise_on_violation: true)

    status, _headers, body = @app.call(env_for('GET', '/n_plus_one'))

    assert_equal 200, status
    assert_equal 'rendered', body.join
    assert_empty @io.string
  end
end
