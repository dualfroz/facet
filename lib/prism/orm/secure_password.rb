require 'openssl'
require 'securerandom'

module Prism
  module Orm
    # `has_secure_password`, Rails-style, without the bcrypt dependency: the
    # digest is PBKDF2-HMAC-SHA256 (stdlib OpenSSL, no gem needed) stored as
    # "iterations$salt$hash" so the cost factor can grow later without
    # invalidating digests written by an older version.
    module SecurePassword
      Iterations = 20_000
      KeyLength = 32

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def secure_password_attributes
          @secure_password_attributes ||= []
        end

        # Defines `password`/`password=`/`password_confirmation=` (virtual,
        # never persisted) plus `authenticate_password` on top of a real
        # `password_digest` column, and wires presence/confirmation checks
        # into the model's own validation pipeline.
        def has_secure_password(attribute = :password, validations: true)
          attribute = attribute.to_sym
          secure_password_attributes << attribute
          digest_column = "#{attribute}_digest"

          define_secure_password_reader(attribute)
          define_secure_password_writer(attribute, digest_column)
          define_secure_password_confirmation_writer(attribute)
          define_secure_password_authenticator(attribute, digest_column)
          hide_from_json(digest_column) if respond_to?(:hide_from_json)

          validate { validate_secure_password(attribute, digest_column) } if validations
        end

        private

        def define_secure_password_reader(attribute)
          define_method(attribute) { secure_password_transient[attribute] }
        end

        def define_secure_password_writer(attribute, digest_column)
          define_method("#{attribute}=") do |unencrypted|
            secure_password_transient[attribute] = unencrypted
            next if unencrypted.nil? || unencrypted.empty?
            self[digest_column] = SecurePassword.digest(unencrypted)
          end
        end

        def define_secure_password_confirmation_writer(attribute)
          define_method("#{attribute}_confirmation=") do |unencrypted|
            secure_password_transient["#{attribute}_confirmation"] = unencrypted
          end
        end

        def define_secure_password_authenticator(attribute, digest_column)
          method_name = attribute == :password ? :authenticate : "authenticate_#{attribute}"
          define_method(method_name) do |unencrypted|
            digest = self[digest_column]
            return false if digest.nil? || digest.empty?
            SecurePassword.verify(digest, unencrypted) ? self : false
          end
        end
      end

      # PBKDF2-HMAC-SHA256 with a fresh random salt per password.
      def self.digest(unencrypted_password)
        salt = SecureRandom.hex(16)
        "#{Iterations}$#{salt}$#{hexdigest(unencrypted_password, salt, Iterations)}"
      end

      def self.verify(digest, unencrypted_password)
        iterations, salt, expected = digest.split('$', 3)
        return false unless iterations && salt && expected
        candidate = hexdigest(unencrypted_password, salt, iterations.to_i)
        secure_compare(candidate, expected)
      end

      def self.hexdigest(password, salt, iterations)
        OpenSSL::PKCS5.pbkdf2_hmac(password.to_s, salt, iterations, KeyLength, OpenSSL::Digest.new('SHA256')).unpack1('H*')
      end

      # Constant-time comparison so a timing attack cannot narrow down a
      # correct digest one byte at a time.
      def self.secure_compare(a, b)
        return false unless a.bytesize == b.bytesize
        left = a.unpack('C*')
        result = 0
        b.each_byte.with_index { |byte, index| result |= byte ^ left[index] }
        result.zero?
      end

      private

      def secure_password_transient
        @secure_password_transient ||= {}
      end

      def validate_secure_password(attribute, digest_column)
        transient = secure_password_transient
        confirmation = transient["#{attribute}_confirmation"]
        if confirmation && transient[attribute] != confirmation
          errors.add(attribute, "doesn't match confirmation")
        end

        current_digest = self[digest_column]
        errors.add(attribute, 'must be present') if new_record? && (current_digest.nil? || current_digest.empty?)
      end
    end
  end
end
