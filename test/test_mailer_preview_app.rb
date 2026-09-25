require 'minitest/autorun'
require 'facet'
require 'support'
require 'tmpdir'
require 'fileutils'

class MailerPreviewAppTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('facet-mailer-preview-app')
    FileUtils.mkdir_p(File.join(@dir, 'preview_widget'))
    File.write(File.join(@dir, 'preview_widget/welcome.text.erb'), "Hi <%= name %>\n")
    File.write(File.join(@dir, 'preview_widget/welcome.html.erb'), "<p>Hi <%= name %></p>\n")

    mailer_dir = @dir
    @mailer_class = Class.new(Facet::Mailer::Base) do
      self.template_roots = [mailer_dir]

      def welcome(name)
        @name = name
        mail(to: 'someone@example.com', from: 'app@example.com', subject: 'Welcome!')
      end
    end
    Object.const_set(:PreviewWidgetMailer, @mailer_class)

    mailer_class = @mailer_class
    @preview_class = Class.new(Facet::Mailer::Preview) do
      define_method(:welcome) { mailer_class.welcome('Fixture Fred') }
    end
    Object.const_set(:WidgetMailerPreview, @preview_class)

    @app = Facet::Mailer::PreviewApp.new
  end

  def teardown
    Facet::Mailer::Preview.registry.delete(@preview_class)
    %i[WidgetMailerPreview PreviewWidgetMailer].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    FileUtils.remove_entry(@dir)
  end

  def call(path, script_name: '')
    env = env_for('GET', path)
    env['SCRIPT_NAME'] = script_name
    @app.call(env)
  end

  def test_index_lists_registered_previews
    status, _, body = call('/')
    assert_equal 200, status
    assert_includes body.join, 'widget_mailer'
  end

  def test_preview_page_lists_its_email_actions
    status, _, body = call('/widget_mailer')
    assert_equal 200, status
    assert_includes body.join, 'welcome'
  end

  def test_email_page_renders_the_actual_rendered_html_body
    status, headers, body = call('/widget_mailer/welcome')
    assert_equal 200, status
    assert_equal 'text/html; charset=UTF-8', headers['Content-Type']
    assert_includes body.join, '<p>Hi Fixture Fred</p>'
    assert_includes body.join, 'Welcome!'
  end

  def test_email_page_never_delivers_the_message
    Facet::Mailer.deliveries.clear
    call('/widget_mailer/welcome')
    assert_empty Facet::Mailer.deliveries
  end

  def test_unknown_preview_is_a_404
    status, = call('/does_not_exist')
    assert_equal 404, status
  end

  def test_unknown_email_action_is_a_404
    status, = call('/widget_mailer/does_not_exist')
    assert_equal 404, status
  end

  def test_links_are_built_from_script_name_so_mounting_anywhere_works
    _, _, body = call('/', script_name: '/rails/mailers')
    assert_includes body.join, 'href="/rails/mailers/widget_mailer"'
  end

  def test_mounted_end_to_end_through_an_application
    host_app = Class.new(Facet::Application) do
      mount '/rails/mailers', Facet::Mailer::PreviewApp.new
    end

    status, _, body = host_app.call(env_for('GET', '/rails/mailers/widget_mailer/welcome'))
    assert_equal 200, status
    assert_includes body.join, '<p>Hi Fixture Fred</p>'
  end
end
