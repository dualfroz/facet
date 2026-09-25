require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class ContentForTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-content-for')
    FileUtils.mkdir_p(File.join(@dir, 'pages'))
    FileUtils.mkdir_p(File.join(@dir, 'layouts'))
    @view = Facet::View.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(relative, source)
    File.write(File.join(@dir, relative), source)
  end

  def test_content_for_slot_is_readable_in_the_layout_rendered_after_it
    write('pages/show.erb', '<% content_for(:title) do %>Custom Title<% end %>Body text')
    write('layouts/application.erb', '[<%= content_for(:title) %>] <%== content %>')

    result = @view.render('pages/show', layout: :application)
    assert_equal '[Custom Title] Body text', result
  end

  def test_content_for_without_a_call_reads_back_empty_string
    write('pages/show.erb', 'Body only')
    write('layouts/application.erb', 'title=[<%= content_for(:title) %>]<%== content %>')

    result = @view.render('pages/show', layout: :application)
    assert_equal 'title=[]Body only', result
  end

  def test_content_for_question_mark_reports_presence
    write('pages/show.erb', '<% content_for(:sidebar) do %>widgets<% end %>')
    write('layouts/application.erb', '<% if content_for?(:sidebar) %>has-sidebar<% else %>no-sidebar<% end %>')

    assert_equal 'has-sidebar', @view.render('pages/show', layout: :application)
  end

  def test_content_for_question_mark_is_false_when_never_set
    write('pages/show.erb', 'nothing here')
    write('layouts/application.erb', '<% if content_for?(:sidebar) %>has-sidebar<% else %>no-sidebar<% end %>')

    assert_equal 'no-sidebar', @view.render('pages/show', layout: :application)
  end

  def test_multiple_content_for_calls_for_the_same_slot_accumulate
    write('pages/show.erb', <<~ERB)
      <% content_for(:scripts) do %>a.js<% end %>
      <% content_for(:scripts) do %>b.js<% end %>
    ERB
    write('layouts/application.erb', '<%= content_for(:scripts) %>')

    assert_equal 'a.jsb.js', @view.render('pages/show', layout: :application)
  end

  def test_content_for_state_does_not_leak_between_separate_render_calls
    write('pages/one.erb', '<% content_for(:title) do %>One<% end %>')
    write('pages/two.erb', 'no title here')
    write('layouts/application.erb', '[<%= content_for(:title) %>]<%== content %>')

    @view.render('pages/one', layout: :application)
    result = @view.render('pages/two', layout: :application)
    assert_equal '[]no title here', result
  end
end
