module Prism
  module Mailer
    # Performs a mailer action out of process. Enqueued by
    # Delivery#deliver_later with the mailer class name (resolved back
    # through Object.const_get, same pattern Jobs::Worker already uses for
    # job classes) so the queue only ever persists plain strings/arrays.
    class DeliveryJob < Prism::Jobs::Job
      queue_as 'mailers'

      def perform(mailer_class_name, action_name, args)
        mailer_class = Object.const_get(mailer_class_name)
        mailer_class.public_send(action_name, *args).deliver_now
      end
    end
  end
end
