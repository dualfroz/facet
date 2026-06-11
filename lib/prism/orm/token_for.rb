module Prism
  module Orm
    # ActiveRecord::TokenFor-lite (Rails 7.1's `generates_token_for`/
    # `find_by_token_for`): a stateless, self-verifying token for one-off
    # flows like "reset my password" or "confirm my email" - no extra
    # column, no row to expire or clean up, just a signed+timestamped
    # MessageVerifier envelope (session 99's expires_in/purpose addition)
    # carrying the record's id and an optional fingerprint block.
    #
    # The fingerprint is what makes a stolen-but-unused reset link stop
    # working the moment its owner acts on it through any OTHER channel:
    # `generates_token_for(:password_reset, expires_in: 900) { password_digest }`
    # bakes the CURRENT password_digest into the token at generation time,
    # so a token minted before a password change fails #find_by_token_for
    # afterwards even though it has not expired and was never explicitly
    # revoked - there is no digest column, so this is otherwise stateless.
    module TokenFor
      class Error < StandardError; end

      class << self
        # One shared secret for every model's generates_token_for, mirroring
        # Encryption.primary_key/MIN Application#enable_attribute_encryption -
        # set once at boot (Application#enable_token_signing), not per model.
        attr_writer :primary_secret

        def primary_secret
          @primary_secret
        end

        # Same rotation contract as Encryption.previous_keys: a token
        # minted under a retired secret still verifies (it just cannot
        # outlive its own expires_in), a fresh token always signs under
        # primary_secret.
        attr_writer :previous_secrets

        def previous_secrets
          @previous_secrets ||= []
        end

        def verifiers
          raise Error, 'Prism::Orm::TokenFor.primary_secret is not set (see Application#enable_token_signing)' unless primary_secret
          [primary_secret, *previous_secrets].map { |secret| Prism::MessageVerifier.new(secret) }
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def token_purposes
          @token_purposes ||= {}
        end

        # `fingerprint` runs in the record's own instance context (like a
        # validation block) so it can read any attribute/method, not just
        # columns - e.g. `{ remember_token_version }` for a value that only
        # changes on an explicit "sign out everywhere" action.
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
