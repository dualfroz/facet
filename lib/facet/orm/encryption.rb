require 'securerandom'

module Facet
  module Orm
    module Encryption
      class Error < StandardError; end

      CIPHER_NAME = 'aes-256-gcm'.freeze
      IV_LENGTH = 12

      class << self
        attr_writer :primary_key

        def primary_key
          @primary_key
        end

        attr_writer :previous_keys

        def previous_keys
          @previous_keys ||= []
        end

        def encrypt(key, value, deterministic:)
          return nil if value.nil?
          plaintext = value.to_s
          iv = deterministic ? OpenSSL::HMAC.digest('SHA256', key, plaintext)[0, IV_LENGTH] : SecureRandom.random_bytes(IV_LENGTH)
          cipher = new_cipher(:encrypt, key, iv)
          ciphertext = cipher.update(plaintext) + cipher.final
          [encode(ciphertext), encode(iv), encode(cipher.auth_tag)].join('--')
        end

        def decrypt(key, message)
          return nil if message.nil?
          ciphertext, iv, auth_tag = message.to_s.split('--', 3)
          raise Error, 'invalid encrypted value' if [ciphertext, iv, auth_tag].any?(&:nil?)

          cipher = new_cipher(:decrypt, key, decode(iv))
          cipher.auth_tag = decode(auth_tag)
          cipher.update(decode(ciphertext)) + cipher.final
        rescue OpenSSL::Cipher::CipherError, ArgumentError, TypeError
          raise Error, 'invalid encrypted value or wrong key'
        end

        def decrypt_with_rotation(key, previous_keys, message)
          return nil if message.nil?
          decrypt(key, message)
        rescue Error => original_error
          previous_keys.each do |previous_key|
            begin
              return decrypt(previous_key, message)
            rescue Error
              next
            end
          end
          raise original_error
        end

        private

        def new_cipher(mode, key, iv)
          cipher = OpenSSL::Cipher.new(CIPHER_NAME)
          cipher.public_send(mode)
          cipher.key = key
          cipher.iv = iv
          cipher.auth_data = ''
          cipher
        end

        def encode(bytes)
          [bytes].pack('m0')
        end

        def decode(text)
          text.unpack1('m0')
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def encrypted_attributes
          inherited = superclass.respond_to?(:encrypted_attributes) ? superclass.encrypted_attributes : {}
          inherited.merge(own_encrypted_attributes)
        end

        def own_encrypted_attributes
          @own_encrypted_attributes ||= {}
        end

        def encrypts(attribute, deterministic: false, key: nil, previous_keys: nil)
          attribute = attribute.to_s
          own_encrypted_attributes[attribute] = { deterministic: deterministic, key: key, previous_keys: previous_keys }
          hide_from_json(attribute)

          define_method(attribute) do
            Encryption.decrypt_with_rotation(self.class.encryption_key_for(attribute),
                                              self.class.encryption_previous_keys_for(attribute),
                                              self[attribute])
          end

          define_method("#{attribute}=") do |value|
            begin
              return if value == public_send(attribute)
            rescue Encryption::Error
              nil
            end
            self[attribute] = Encryption.encrypt(self.class.encryption_key_for(attribute), value, deterministic: deterministic)
          end
        end

        def encryption_key_for(attribute)
          attribute = attribute.to_s
          @encryption_keys ||= {}
          @encryption_keys[attribute] ||= begin
            secret = encryption_config_for(attribute)[:key] || Encryption.primary_key
            raise Error, 'Facet::Orm::Encryption.primary_key= (or Application#enable_attribute_encryption) must be set before using `encrypts`, unless a key: is given' unless secret
            derive_encryption_key(attribute, secret)
          end
        end

        def encryption_previous_keys_for(attribute)
          attribute = attribute.to_s
          @encryption_previous_keys ||= {}
          @encryption_previous_keys[attribute] ||= begin
            secrets = encryption_config_for(attribute)[:previous_keys] || Encryption.previous_keys
            secrets.map { |secret| derive_encryption_key(attribute, secret) }
          end
        end

        def encrypt_for_query(attribute, value)
          raise Error, "#{attribute} is not deterministic, cannot query #{name} by its plaintext value" unless encryption_config_for(attribute)[:deterministic]
          return nil if value.nil?
          candidates = [Encryption.encrypt(encryption_key_for(attribute), value, deterministic: true)]
          encryption_previous_keys_for(attribute).each do |previous_key|
            candidates << Encryption.encrypt(previous_key, value, deterministic: true)
          end
          candidates.size == 1 ? candidates.first : candidates
        end

        private

        def encryption_config_for(attribute)
          encrypted_attributes.fetch(attribute.to_s) { raise Error, "#{attribute} is not an encrypted attribute on #{name}" }
        end

        def derive_encryption_key(attribute, secret)
          MessageEncryptor.derive_key(secret, salt: "facet-orm-encryption/#{table_name}/#{attribute}")
        end
      end
    end
  end
end
