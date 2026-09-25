require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class PaginationHelpersTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-pagination-helpers')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name position])
    widget_class = Class.new(Facet::Orm::Model) { table_name :widgets }
    widget_class.store = @store
    Object.const_set(:PaginatedWidget, widget_class)
    25.times { |i| PaginatedWidget.create!(name: "widget-#{i}", position: i) }

    @context = Facet::Template::Context.new({})
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :PaginatedWidget) if Object.const_defined?(:PaginatedWidget)
  end

  def path_for
    ->(page) { "/widgets?page=#{page}" }
  end

  def test_returns_blank_when_everything_fits_on_one_page
    relation = PaginatedWidget.page(1)
    assert_equal '', @context.paginate(relation, path: path_for)
  end

  def test_renders_a_link_per_page_within_the_window
    relation = PaginatedWidget.order(:position).page(1).per(5)
    html = @context.paginate(relation, path: path_for)
    assert_includes html, 'href="/widgets?page=2"'
    assert_includes html, '>2<'
  end

  def test_current_page_link_carries_the_current_class
    relation = PaginatedWidget.order(:position).page(3).per(5)
    html = @context.paginate(relation, path: path_for)
    assert_includes html, 'href="/widgets?page=3" class="page-link current"'
  end

  def test_first_page_disables_the_previous_link
    relation = PaginatedWidget.order(:position).page(1).per(5)
    html = @context.paginate(relation, path: path_for)
    assert_includes html, '<span class="page-link disabled">Previous</span>'
  end

  def test_last_page_disables_the_next_link
    relation = PaginatedWidget.order(:position).page(5).per(5)
    html = @context.paginate(relation, path: path_for)
    assert_includes html, '<span class="page-link disabled">Next</span>'
  end

  def test_far_apart_pages_are_separated_by_a_gap_marker
    relation = PaginatedWidget.order(:position).page(1).per(1)
    html = @context.paginate(relation, path: path_for)
    assert_includes html, '<span class="page-gap">...</span>'
  end

  def test_renders_through_a_real_erb_template
    views_dir = File.join(@dir, 'views', 'widgets')
    FileUtils.mkdir_p(views_dir)
    File.write(File.join(views_dir, 'index.erb'), '<%== paginate(widgets, path: ->(n) { "/widgets?page=#{n}" }) %>')

    view = Facet::View.new(File.join(@dir, 'views'))
    output = view.render('widgets/index', locals: { widgets: PaginatedWidget.order(:position).page(1).per(5) })
    assert_includes output, '<nav class="pagination">'
    assert_includes output, 'href="/widgets?page=2"'
  end
end
