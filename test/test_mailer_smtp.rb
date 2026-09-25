require 'minitest/autorun'
require 'facet'
require 'socket'

class FakeSmtpServer
  attr_reader :commands, :data

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @commands = []
    @data = nil
    @mutex = Mutex.new
  end

  def port
    @server.addr[1]
  end

  def start
    @thread = Thread.new { accept_loop }
    self
  end

  def stop
    @server.close
    @thread&.join(1)
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      handle(client)
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(client)
    client.print "220 fake.smtp ready\r\n"
    loop do
      line = client.gets
      break unless line

      record(line.chomp)
      break unless dispatch(client, line)
    end
  end

  def record(line)
    @mutex.synchronize { @commands << line }
  end

  def dispatch(client, line)
    case line
    when /\A(EHLO|HELO)/i
      client.print "250 fake.smtp\r\n"
    when /\AMAIL FROM/i, /\ARCPT TO/i
      client.print "250 OK\r\n"
    when /\ADATA/i
      client.print "354 go ahead\r\n"
      read_data(client)
      client.print "250 OK queued\r\n"
    when /\AQUIT/i
      client.print "221 bye\r\n"
      return false
    else
      client.print "500 unrecognized\r\n"
    end
    true
  end

  def read_data(client)
    body = +''
    while (line = client.gets)
      break if line == ".\r\n"

      body << line
    end
    @mutex.synchronize { @data = body }
  end
end

class MailerSmtpTest < Minitest::Test
  def setup
    @previous_method = Facet::Mailer.delivery_method
    @previous_settings = Facet::Mailer.smtp_settings
  end

  def teardown
    Facet::Mailer.delivery_method = @previous_method
    Facet::Mailer.smtp_settings = @previous_settings
  end

  def test_smtp_delivery_speaks_real_smtp_to_a_live_server_over_tcp
    server = FakeSmtpServer.new.start
    Facet::Mailer.delivery_method = :smtp
    Facet::Mailer.smtp_settings = { address: '127.0.0.1', port: server.port, domain: 'test.local' }

    message = Facet::Mailer::Message.new
    message.from = 'sender@example.com'
    message.to = 'receiver@example.com'
    message.subject = 'Live SMTP test'
    message.text_body = 'delivered over a real socket'

    Facet::Mailer.deliver!(message)
    server.stop

    assert(server.commands.any? { |c| c =~ /\AMAIL FROM:<sender@example\.com>/i })
    assert(server.commands.any? { |c| c =~ /\ARCPT TO:<receiver@example\.com>/i })
    assert_includes server.data, 'delivered over a real socket'
    assert_includes server.data, 'Subject: Live SMTP test'
  end

  def test_smtp_delivery_raises_when_no_server_is_listening
    Facet::Mailer.delivery_method = :smtp
    Facet::Mailer.smtp_settings = { address: '127.0.0.1', port: 1, domain: 'test.local' }

    message = Facet::Mailer::Message.new
    message.from = 'sender@example.com'
    message.to = 'receiver@example.com'
    message.subject = 'Unreachable'
    message.text_body = 'never sent'

    assert_raises(StandardError) { Facet::Mailer.deliver!(message) }
  end

  def test_unknown_delivery_method_raises_immediately
    Facet::Mailer.delivery_method = :carrier_pigeon
    message = Facet::Mailer::Message.new
    message.from = 'sender@example.com'
    message.to = 'receiver@example.com'
    message.subject = 'x'
    message.text_body = 'x'

    assert_raises(ArgumentError) { Facet::Mailer.deliver!(message) }
  end
end
