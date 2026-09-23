module Facet
  module Mailer
    class DeliveryJob < Facet::Jobs::Job
      queue_as 'mailers'

      def perform(mailer_class_name, action_name, args)
        mailer_class = Object.const_get(mailer_class_name)
        mailer_class.public_send(action_name, *args).deliver_now
      end
    end
  end
end
