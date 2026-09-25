require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class FragmentCacheViewerIndependentTest < Minitest::Test
  def setup
    Facet::Cache.store.clear
    @dir = Dir.mktmpdir('facet-fragment-cache-viewer')
    FileUtils.mkdir_p(File.join(@dir, 'pages'))
    @view = Facet::View.new(@dir)
    write('pages/show.erb', <<~ERB)
      <% cache(:recent_posts_sidebar, expires_in: 60) do %>
      <%= render_count! %> recent posts, none of them yours
      <% end %>
      signed in as <%= viewer %>
    ERB
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Facet::Cache.store.clear
  end

  def write(relative, source)
    File.write(File.join(@dir, relative), source)
  end

  def render_as(viewer, tracker)
    @view = Facet::View.new(@dir, helpers: Tracker.new(tracker))
    @view.render('pages/show', locals: { viewer: viewer })
  end

  def test_cache_block_renders_once_and_is_shared_across_different_viewers
    tracker = []

    anon_output = render_as('anonymous', tracker)
    alice_output = render_as('alice', tracker)
    bob_output = render_as('bob', tracker)

    assert_equal 1, tracker.size,
                 'the fragment inside cache() should render exactly once total, not once per viewer'
    assert_includes anon_output, '1 recent posts, none of them yours'
    cached_line = anon_output.lines.find { |line| line.include?('recent posts') }
    assert_equal cached_line, alice_output.lines.find { |line| line.include?('recent posts') }
    assert_equal cached_line, bob_output.lines.find { |line| line.include?('recent posts') }
  end

  def test_content_outside_the_cache_block_still_varies_per_viewer
    tracker = []

    anon_output = render_as('anonymous', tracker)
    alice_output = render_as('alice', tracker)

    assert_includes anon_output, 'signed in as anonymous'
    assert_includes alice_output, 'signed in as alice'
    refute_equal anon_output, alice_output,
                 'the viewer-dependent line must still differ even though the cached fragment is shared'
  end

  class Tracker
    def initialize(calls)
      @calls = calls
    end

    def render_count!
      @calls << true
      @calls.size
    end
  end
end
