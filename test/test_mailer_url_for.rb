require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class MailerUrlForTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-mailer-url-for')
    FileUtils.mkdir_p(File.join(@dir, 'url_for'))
    write('url_for/welcome.text.erb', "Click here: <%= url_for(:confirmation, id: user_id) %>\n")

    @router = Facet::Router.new
    @router.add('get', '/confirmations/:id', name: :confirmation)

    mailer_dir = @dir
    @mailer_class = Class.new(Facet::Mailer::Base) do
      self.template_roots = [mailer_dir]

      def welcome(user_id)
        @user_id = user_id
        mail(to: 'someone@example.com', subject: 'Welcome!')
      end
    end
    Object.const_set(:UrlForMailer, @mailer_class)
  end

  def teardown
    Object.send(:remove_const, :UrlForMailer) if Object.const_defined?(:UrlForMailer)
    FileUtils.remove_entry(@dir)
    Facet::Mailer.router = nil
    Facet::Mailer.default_url_options = nil
  end

  def write(relative, source)
    File.write(File.join(@dir, relative), source)
  end

  def test_url_for_raises_without_a_configured_router
    Facet::Mailer.router = nil
    error = assert_raises(RuntimeError) { UrlForMailer.welcome(42) }
    assert_match(/no router configured/, error.message)
  end

  def test_url_for_raises_without_a_host
    Facet::Mailer.router = @router
    error = assert_raises(ArgumentError) { UrlForMailer.welcome(42) }
    assert_match(/:host/, error.message)
  end

  def test_url_for_builds_an_absolute_url_from_global_default_url_options
    Facet::Mailer.router = @router
    Facet::Mailer.default_url_options = { host: 'example.com' }

    body = UrlForMailer.welcome(42).message.text_body
    assert_equal "Click here: http://example.com/confirmations/42\n", body
  end

  def test_per_mailer_class_default_url_options_win_over_the_global_ones
    Facet::Mailer.router = @router
    Facet::Mailer.default_url_options = { host: 'example.com', protocol: 'http' }
    UrlForMailer.default_url_options(host: 'mail.example.com', protocol: 'https')

    body = UrlForMailer.welcome(42).message.text_body
    assert_equal "Click here: https://mail.example.com/confirmations/42\n", body
  end

  def test_port_is_included_when_given
    Facet::Mailer.router = @router
    Facet::Mailer.default_url_options = { host: 'example.com', port: 3000 }

    body = UrlForMailer.welcome(42).message.text_body
    assert_equal "Click here: http://example.com:3000/confirmations/42\n", body
  end

  def test_application_enable_mailer_wires_router_and_default_url_options
    app_class = Class.new(Facet::Application)
    app_class.router.add('get', '/confirmations/:id', name: :confirmation)
    app_class.enable_mailer(host: 'app.example.com', protocol: 'https')

    assert_same app_class.router, Facet::Mailer.router
    assert_equal({ host: 'app.example.com', protocol: 'https' }, Facet::Mailer.default_url_options)

    body = UrlForMailer.welcome(7).message.text_body
    assert_equal "Click here: https://app.example.com/confirmations/7\n", body
  end
end
