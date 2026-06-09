module Prism
  module Mailer
    # ActionMailer::Preview-lite: subclass and define one instance method per
    # preview action that returns a mailer Delivery built from fixture data
    # (`UserMailer.welcome(sample_user)`) instead of a real request/record -
    # so an email's rendered HTML/text can be inspected without sending it or
    # ever touching Mailer.deliver!. Every subclass self-registers so a host
    # app can list and browse them (e.g. mount them under a dev-only route).
    class Preview
      class << self
        def registry
          @registry ||= []
        end

        def inherited(subclass)
          registry << subclass
        end

        def preview_name
          Inflector.underscore(name.to_s.split('::').last.sub(/Preview\z/, ''))
        end

        def emails
          instance_methods(false).map(&:to_s).sort
        end

        # Renders one preview action by name and returns its Delivery
        # (message.html_body / message.text_body / message.subject, ...);
        # never calls #deliver_now or #deliver_later.
        def call(email)
          email = email.to_s
          unless emails.include?(email)
            raise ArgumentError, "unknown preview #{email.inspect} for #{self} (known: #{emails.join(', ')})"
          end
          new.public_send(email)
        end

        def find(preview_name)
          registry.find { |klass| klass.preview_name == preview_name.to_s }
        end
      end
    end
  end
end
