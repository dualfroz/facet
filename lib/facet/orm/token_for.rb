module Facet
  module Orm
    module TokenFor
      class Error < StandardError; end

      class << self
        attr_writer :primary_secret

        def primary_secret
          @primary_secret
        end

        attr_writer :previous_secrets

        def previous_secrets
          @previous_secrets ||= []
        end

        def verifiers
          raise Error, 'Facet::Orm::TokenFor.primary_secret is not set (see Application#enable_token_signing)' unless primary_secret
          [primary_secret, *previous_secrets].map { |secret| Facet::MessageVerifier.new(secret) }
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def token_purposes
          @token_purposes ||= {}
        end

        def generates_token_for(purpose, expires_in: nil, &fingerprint)
          token_purposes[purpose.to_s] = { expires_in: expires_in, fingerprint: fingerprint }
        end

        def find_by_token_for(purpose, token)
          return nil if token.to_s.empty?
          config = token_config_for!(purpose)
          payload = verify_token(purpose, token)
          return nil unless payload

          record = find_by(id: payload['id'])
          return nil unless record
          return nil unless fingerprint_matches?(record, config, payload['fp'])
          record
        end

        private

        def token_config_for!(purpose)
          token_purposes[purpose.to_s] || raise(TokenFor::Error, "#{name} has no generates_token_for(:#{purpose})")
        end

        def verify_token(purpose, token)
          TokenFor.verifiers.each do |verifier|
            payload = verifier.verified(token, purpose: "#{name}/#{purpose}")
            return payload if payload
          end
          nil
        end

        def fingerprint_matches?(record, config, token_fingerprint)
          return token_fingerprint.nil? unless config[:fingerprint]
          record.instance_exec(&config[:fingerprint]) == token_fingerprint
        end
      end

      def generate_token_for(purpose)
        config = self.class.token_purposes[purpose.to_s] ||
                 raise(TokenFor::Error, "#{self.class.name} has no generates_token_for(:#{purpose})")
        fingerprint = config[:fingerprint] ? instance_exec(&config[:fingerprint]) : nil
        verifier = TokenFor.verifiers.first
        verifier.generate({ 'id' => id, 'fp' => fingerprint }, expires_in: config[:expires_in], purpose: "#{self.class.name}/#{purpose}")
      end
    end
  end
end
