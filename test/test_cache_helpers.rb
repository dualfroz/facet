require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class CacheHelpersTest < Minitest::Test
  def setup
    Prism::Cache.store.clear
    @dir = Dir.mktmpdir('prism-cache-helpers')
    FileUtils.mkdir_p(File.join(@dir, 'pages'))
    @view = Prism::View.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Prism::Cache.store.clear
  end

  def write(relative, source)
    File.write(File.join(@dir, relative), source)
  end

  def test_cache_block_renders_and_stores_the_fragment
    write('pages/show.erb', '<% cache("greeting") do %><%= greeting %><% end %>')
    result = @view.render('pages/show', locals: { greeting: 'hi' })
    assert_equal 'hi', result
    assert_equal 'hi', Prism::Cache.store.read('greeting')
  end

  def test_cache_block_is_not_reevaluated_on_a_hit
    calls = []
    write('pages/show.erb', '<% cache("counter") do %><%= track! %><% end %>')
    @view = Prism::View.new(@dir, helpers: CounterHelper.new(calls))

    first = @view.render('pages/show')
    second = @view.render('pages/show')

    assert_equal first, second
    assert_equal 1, calls.size
  end

  def test_cache_key_can_be_an_array_mixing_scope_and_a_model
    model = Struct.new(:cache_key).new('posts/7-42')
    write('pages/show.erb', '<% cache([:sidebar, model]) do %>rendered<% end %>')
    @view.render('pages/show', locals: { model: model })
    assert @view.expand_cache_key([:sidebar, model]) == 'sidebar/posts/7-42'
    assert_equal 'rendered', Prism::Cache.store.read('sidebar/posts/7-42')
  end

  def test_expires_in_evicts_the_entry_after_the_given_time
    write('pages/show.erb', '<% cache("temp", expires_in: 0) do %>value<% end %>')
    @view.render('pages/show')
    sleep 0.01
    assert_nil Prism::Cache.store.read('temp')
  end

  class CounterHelper
    def initialize(calls)
      @calls = calls
    end

    def track!
      @calls << true
      'x'
    end
  end
end
