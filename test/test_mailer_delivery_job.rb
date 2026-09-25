require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class MailerDeliveryJobTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-mailer-delivery-job')
    FileUtils.mkdir_p(File.join(@dir, 'templates', 'ping'))
    File.write(File.join(@dir, 'templates', 'ping', 'ping.text.erb'), "ping <%= name %>\n")

    Facet::Mailer.deliveries.clear
    Facet::Mailer.delivery_method = :test

    template_dir = File.join(@dir, 'templates')
    @mailer_class = Class.new(Facet::Mailer::Base) do
      self.template_roots = [template_dir]
      default from: 'jobs@example.com'

      def ping(user)
        @name = user[:name]
        mail(to: user[:email], subject: 'Ping')
      end
    end
    Object.const_set(:PingMailer, @mailer_class)

    @queue = Facet::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    @previous_queue = Facet::Jobs.default_queue
    Facet::Jobs.default_queue = @queue
  end

  def teardown
    Facet::Jobs.default_queue = @previous_queue
    Object.send(:remove_const, :PingMailer) if Object.const_defined?(:PingMailer)
    FileUtils.remove_entry(@dir)
  end

  def test_deliver_later_enqueues_a_real_job_that_a_worker_can_process
    PingMailer.ping(name: 'Finn', email: 'finn@example.com').deliver_later
    assert_equal 1, @queue.size

    worker = Facet::Jobs::Worker.new(@queue)
    processed = worker.work_off

    assert_equal 1, processed
    assert_equal 0, @queue.size
    assert_equal 1, Facet::Mailer.deliveries.size
    assert_includes Facet::Mailer.deliveries.last.to_s, 'ping Finn'
  end

  def test_deliver_later_job_survives_reading_back_from_a_freshly_opened_queue
    PingMailer.ping(name: 'Gwen', email: 'gwen@example.com').deliver_later

    reopened = Facet::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    worker = Facet::Jobs::Worker.new(reopened)
    assert_equal 1, worker.work_off
    assert_equal 1, Facet::Mailer.deliveries.size
  end

  def test_failed_delivery_is_retried_then_dead_lettered_like_any_other_job
    PingMailer.ping(name: 'Hana', email: 'hana@example.com').deliver_later(queue: 'mailers')
    Facet::Mailer.delivery_method = :smtp
    Facet::Mailer.smtp_settings = { address: '127.0.0.1', port: 1 }

    worker = Facet::Jobs::Worker.new(@queue, queue_name: 'mailers')
    5.times do
      worker.work_off
      force_all_due
    end

    assert_equal 1, @queue.dead_letter_size
    assert_equal 0, Facet::Mailer.deliveries.size
  ensure
    Facet::Mailer.delivery_method = :test
  end

  private

  def force_all_due
    pstore = @queue.instance_variable_get(:@pstore)
    pstore.transaction { pstore[:jobs].each_value { |job| job[:run_at] = Time.now - 1 } }
  end
end
