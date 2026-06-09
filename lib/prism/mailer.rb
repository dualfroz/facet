require_relative 'mailer/message'
require_relative 'mailer/delivery'
require_relative 'mailer/delivery_job'
require_relative 'mailer/base'
require_relative 'mailer/preview'
require_relative 'mailer/preview_app'

module Prism
  module Mailer
    class << self
      attr_accessor :smtp_settings

      # Router used by Mailer::Base#url_for to build absolute links inside
      # mail bodies, where there is no incoming request to pull a router off
      # of. Set once, normally via Application#enable_mailer, e.g.
      # `Prism::Mailer.router = BlogApp.router`.
      attr_accessor :router
      attr_writer :delivery_method, :default_url_options

      def delivery_method
        @delivery_method ||= :test
      end

      # App-wide fallback for Mailer::Base.default_url_options (host,
      # protocol, port); a mailer class's own default_url_options take
      # precedence when both are set.
      def default_url_options
        @default_url_options ||= {}
      end

      # Messages handed to Mailer.deliver! while delivery_method == :test
      # pile up here instead of going out over the network, mirroring
      # ActionMailer::Base.deliveries for assertions in tests.
      def deliveries
        @deliveries ||= []
      end

      def deliver!(message)
        Instrumentation.instrument('deliver_mail.prism', subject: message.subject,
                                                           to: message.to,
                                                           delivery_method: delivery_method) do
          case delivery_method
          when :test
            deliveries << message
          when :smtp
            deliver_via_smtp(message)
          else
            raise ArgumentError, "unknown Prism::Mailer.delivery_method #{delivery_method.inspect}"
          end
        end
        message
      end

      private

      def deliver_via_smtp(message)
        require 'net/smtp'
        settings = smtp_settings || {}
        Net::SMTP.start(settings[:address] || 'localhost', settings[:port] || 25,
                         settings[:domain] || 'localhost', settings[:user_name],
                         settings[:password], settings[:authentication]) do |smtp|
          smtp.send_message(message.to_s, message.from, message.all_recipients)
        end
      end
    end
  end
end
