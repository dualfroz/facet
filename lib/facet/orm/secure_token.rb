require 'securerandom'

module Facet
  module Orm
    module SecureToken
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def secure_token_attributes
          @secure_token_attributes ||= []
        end

        def has_secure_token(attribute = :token, length: 24)
          attribute = attribute.to_sym
          secure_token_attributes << attribute

          before_create { self[attribute] = SecureToken.generate(length) if self[attribute].to_s.empty? }

          define_method("regenerate_#{attribute}!") do
            update!(attribute => SecureToken.generate(length))
          end
        end
      end

      def self.generate(length = 24)
        SecureRandom.urlsafe_base64(length, padding: false)
      end
    end
  end
end
