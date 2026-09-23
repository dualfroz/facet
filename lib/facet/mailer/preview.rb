module Facet
  module Mailer
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
