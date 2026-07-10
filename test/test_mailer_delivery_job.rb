require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class MailerDeliveryJobTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-mailer-delivery-job')
    FileUtils.mkdir_p(File.join(@dir, 'templates', 'ping'))
    File.write(File.join(@dir, 'templates', 'ping', 'ping.text.erb'), "ping <%= name %>\n")

    Prism::Mailer.deliveries.clear
    Prism::Mailer.delivery_method = :test

    template_dir = File.join(@dir, 'templates')
    @mailer_class = Class.new(Prism::Mailer::Base) do
      self.template_roots = [template_dir]
      default from: 'jobs@example.com'

      def ping(user)
        @name = user[:name]
        mail(to: user[:email], subject: 'Ping')
      end
    end
    Object.const_set(:PingMailer, @mailer_class)

    @queue = Prism::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    @previous_queue = Prism::Jobs.default_queue
    Prism::Jobs.default_queue = @queue
  end

  def teardown
    Prism::Jobs.default_queue = @previous_queue
    Object.send(:remove_const, :PingMailer) if Object.const_defined?(:PingMailer)
    FileUtils.remove_entry(@dir)
  end

  def test_deliver_later_enqueues_a_real_job_that_a_worker_can_process
    PingMailer.ping(name: 'Finn', email: 'finn@example.com').deliver_later
    assert_equal 1, @queue.size

    worker = Prism::Jobs::Worker.new(@queue)
    processed = worker.work_off

    assert_equal 1, processed
    assert_equal 0, @queue.size
    assert_equal 1, Prism::Mailer.deliveries.size
    assert_includes Prism::Mailer.deliveries.last.to_s, 'ping Finn'
  end

  def test_deliver_later_job_survives_reading_back_from_a_freshly_opened_queue
    PingMailer.ping(name: 'Gwen', email: 'gwen@example.com').deliver_later

    reopened = Prism::Jobs::Queue.new(File.join(@dir, 'jobs.pstore'))
    worker = Prism::Jobs::Worker.new(reopened)
    assert_equal 1, worker.work_off
    assert_equal 1, Prism::Mailer.deliveries.size
  end

  def test_failed_delivery_is_retried_then_dead_lettered_like_any_other_job
    PingMailer.ping(name: 'Hana', email: 'hana@example.com').deliver_later(queue: 'mailers')
    Prism::Mailer.delivery_method = :smtp
    Prism::Mailer.smtp_settings = { address: '127.0.0.1', port: 1 }

    worker = Prism::Jobs::Worker.new(@queue, queue_name: 'mailers')
    5.times do
      worker.work_off
      force_all_due
    end

    assert_equal 1, @queue.dead_letter_size
    assert_equal 0, Prism::Mailer.deliveries.size
  ensure
    Prism::Mailer.delivery_method = :test
  end

  private

  # Same trick as test_jobs_worker.rb: retries are scheduled with real
  # backoff into the future, so tests pull run_at back into the past
  # instead of sleeping for it.
  def force_all_due
    pstore = @queue.instance_variable_get(:@pstore)
    pstore.transaction { pstore[:jobs].each_value { |job| job[:run_at] = Time.now - 1 } }
  end
end
