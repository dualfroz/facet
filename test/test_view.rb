require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class ViewTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-view')
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    FileUtils.mkdir_p(File.join(@dir, 'layouts'))
    File.write(File.join(@dir, 'posts', 'index.erb'), '<%= greeting %>')
    File.write(File.join(@dir, 'posts', '_item.erb'), '[<%= label %>]')
    File.write(File.join(@dir, 'layouts', 'application.erb'), 'before-<%== content %>-after')
    @view = Prism::View.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_render_reads_and_evaluates_template
    assert_equal 'hi', @view.render('posts/index', locals: { greeting: 'hi' })
  end

  def test_render_wraps_content_with_layout
    result = @view.render('posts/index', locals: { greeting: 'hi' }, layout: :application)
    assert_equal 'before-hi-after', result
  end

  def test_render_partial_directly
    assert_equal '[x]', @view.render_partial('posts/item', locals: { label: 'x' })
  end

  def test_partial_called_from_within_a_template_resolves_relative_to_it
    File.write(File.join(@dir, 'posts', 'index.erb'), "<%== partial('item', locals: { label: greeting }) %>")
    assert_equal '[hi]', @view.render('posts/index', locals: { greeting: 'hi' })
  end

  def test_render_collection_exposes_item_and_counter_locals
    File.write(File.join(@dir, 'posts', '_item.erb'), '<%= label_counter %>:<%= label %>;')
    result = @view.render_collection('posts/item', %w[a b], as: :label)
    assert_equal '1:a;2:b;', result
  end

  def test_render_collection_defaults_local_name_to_partial_basename
    File.write(File.join(@dir, 'posts', '_item.erb'), '<%= item %>;')
    result = @view.render_collection('posts/item', %w[a b])
    assert_equal 'a;b;', result
  end

  def test_missing_template_raises_a_descriptive_error
    error = assert_raises(Prism::View::TemplateNotFound) { @view.render('posts/missing') }
    assert_includes error.message, 'posts/missing'
  end

  def test_render_emits_a_render_template_event_per_template_file
    events = []
    subscriber = Prism::Instrumentation.subscribe('render_template.prism') { |event| events << event }
    begin
      @view.render('posts/index', locals: { greeting: 'hi' }, layout: :application)
    ensure
      Prism::Instrumentation.unsubscribe(subscriber)
    end

    assert_equal %w[posts/index layouts/application], events.map { |e| e.payload[:identifier] }
  end
end
