require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class MailerBaseTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-mailer-base')
    FileUtils.mkdir_p(File.join(@dir, 'user'))
    Prism::Mailer.deliveries.clear
    Prism::Mailer.delivery_method = :test

    write('user/welcome.text.erb', "Hi <%= name %>, welcome!\n")
    write('user/welcome.html.erb', "<p>Hi <%= name %>, welcome!</p>\n")
    write('user/text_only.text.erb', "plain only for <%= name %>\n")

    mailer_dir = @dir
    @mailer_class = Class.new(Prism::Mailer::Base) do
      self.template_roots = [mailer_dir]
      default from: 'noreply@example.com'

      def welcome(user)
        @name = user[:name]
        mail(to: user[:email], subject: 'Welcome!')
      end

      def text_only(user)
        @name = user[:name]
        mail(to: user[:email], subject: 'Plain', template: 'text_only')
      end

      def missing_template(user)
        mail(to: user[:email], subject: 'Nope', template: 'does_not_exist')
      end
    end
    Object.const_set(:UserMailer, @mailer_class)
  end

  def teardown
    Object.send(:remove_const, :UserMailer) if Object.const_defined?(:UserMailer)
    FileUtils.remove_entry(@dir)
  end

  def write(relative, source)
    File.write(File.join(@dir, relative), source)
  end

  def test_mailer_name_strips_the_mailer_suffix_and_underscores
    assert_equal 'user', UserMailer.mailer_name
  end

  def test_calling_an_action_as_a_class_method_renders_both_bodies_with_auto_locals
    delivery = UserMailer.welcome(name: 'Ada', email: 'ada@example.com')
    message = delivery.message
    assert_equal ['ada@example.com'], message.to
    assert_equal 'Welcome!', message.subject
    assert_equal 'noreply@example.com', message.from
    assert_equal "Hi Ada, welcome!\n", message.text_body
    assert_equal "<p>Hi Ada, welcome!</p>\n", message.html_body
  end

  def test_default_options_apply_before_the_action_runs
    delivery = UserMailer.welcome(name: 'Bob', email: 'bob@example.com')
    assert_equal 'noreply@example.com', delivery.message.from
  end

  def test_deliver_now_hands_the_message_to_prism_mailer
    UserMailer.welcome(name: 'Cleo', email: 'cleo@example.com').deliver_now
    assert_equal 1, Prism::Mailer.deliveries.size
    assert_includes Prism::Mailer.deliveries.last.to_s, 'Cleo'
  end

  def test_deliver_now_publishes_deliver_mail_instrumentation_event
    events = []
    subscriber = Prism::Instrumentation.subscribe('deliver_mail.prism') { |event| events << event }

    UserMailer.welcome(name: 'Eve', email: 'eve@example.com').deliver_now

    assert_equal 1, events.size
    assert_equal 'Welcome!', events.first.payload[:subject]
    assert_equal ['eve@example.com'], events.first.payload[:to]
    assert_equal :test, events.first.payload[:delivery_method]
    assert_kind_of Float, events.first.duration
  ensure
    Prism::Instrumentation.unsubscribe(subscriber)
  end

  def test_explicit_template_option_overrides_the_action_name
    delivery = UserMailer.text_only(name: 'Dee', email: 'dee@example.com')
    assert_equal "plain only for Dee\n", delivery.message.text_body
    assert_nil delivery.message.html_body
  end

  def test_missing_template_for_both_variants_raises_template_not_found
    assert_raises(Prism::View::TemplateNotFound) do
      UserMailer.missing_template(email: 'nobody@example.com')
    end
  end

  def test_unknown_class_method_still_raises_no_method_error
    assert_raises(NoMethodError) { UserMailer.does_not_exist_at_all }
  end

  def test_responds_to_defined_actions_but_not_arbitrary_names
    assert UserMailer.respond_to?(:welcome)
    refute UserMailer.respond_to?(:not_a_real_action)
  end
end
