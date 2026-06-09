module Prism
  module Mailer
    # Returned by a mailer action call (`UserMailer.welcome(user)`), in the
    # spirit of ActionMailer's MessageDelivery: the message is already
    # rendered at this point, #deliver_now hands it to Prism::Mailer.deliver!
    # immediately, #deliver_later re-enqueues the action itself (mailer
    # class, action name, args) as a Prism::Jobs::Job so a Worker performs
    # the rendering and delivery out of process.
    class Delivery
      def initialize(message, mailer_class:, action_name:, args:)
        @message = message
        @mailer_class = mailer_class
        @action_name = action_name
        @args = args
      end

      attr_reader :message

      def deliver_now
        Mailer.deliver!(message)
      end

      def deliver_later(queue: nil, run_at: nil)
        DeliveryJob.perform_later(@mailer_class.name, @action_name, @args, queue: queue, run_at: run_at)
      end
    end
  end
end
