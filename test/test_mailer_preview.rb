require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class MailerPreviewTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-mailer-preview')
    FileUtils.mkdir_p(File.join(@dir, 'preview_user'))
    File.write(File.join(@dir, 'preview_user/welcome.text.erb'), "Hi <%= name %>\n")

    mailer_dir = @dir
    @mailer_class = Class.new(Prism::Mailer::Base) do
      self.template_roots = [mailer_dir]

      def welcome(name)
        @name = name
        mail(to: 'someone@example.com', subject: 'Welcome!')
      end
    end
    Object.const_set(:PreviewUserMailer, @mailer_class)

    mailer_class = @mailer_class
    @preview_class = Class.new(Prism::Mailer::Preview) do
      define_method(:welcome) { mailer_class.welcome('Fixture Fred') }
    end
    Object.const_set(:UserMailerPreview, @preview_class)
  end

  def teardown
    Prism::Mailer::Preview.registry.delete(@preview_class)
    %i[UserMailerPreview PreviewUserMailer].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    FileUtils.remove_entry(@dir)
  end

  def test_subclassing_registers_the_preview
    assert_includes Prism::Mailer::Preview.registry, UserMailerPreview
  end

  def test_preview_name_strips_the_preview_suffix_and_underscores
    assert_equal 'user_mailer', UserMailerPreview.preview_name
  end

  def test_emails_lists_the_defined_preview_actions
    assert_equal ['welcome'], UserMailerPreview.emails
  end

  def test_call_renders_the_action_and_returns_its_delivery
    delivery = UserMailerPreview.call(:welcome)
    assert_equal "Hi Fixture Fred\n", delivery.message.text_body
  end

  def test_call_never_delivers_the_message
    Prism::Mailer.deliveries.clear
    UserMailerPreview.call(:welcome)
    assert_empty Prism::Mailer.deliveries
  end

  def test_call_raises_for_an_unknown_email
    error = assert_raises(ArgumentError) { UserMailerPreview.call(:does_not_exist) }
    assert_match(/unknown preview/, error.message)
  end

  def test_find_looks_up_a_registered_preview_by_name
    assert_equal UserMailerPreview, Prism::Mailer::Preview.find('user_mailer')
    assert_nil Prism::Mailer::Preview.find('nonexistent')
  end
end
