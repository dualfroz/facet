require 'securerandom'

module Prism
  module Orm
    # ActiveRecord::Encryption-lite: transparent attribute encryption at
    # rest, riding on the same AES-256-GCM primitive as MessageEncryptor
    # (Prism::Security) rather than a second crypto implementation. Every
    # encrypted column gets its OWN derived key (HKDF-style salt namespaced
    # by table+attribute) from one shared application secret, so leaking the
    # ciphertext and key of one column never helps decrypt another, and the
    # same secret can safely also back cookies/CSRF elsewhere in the app -
    # `MessageEncryptor.derive_key` is what makes that separation free.
    #
    # `encrypts :ssn` stores ciphertext in the underlying column and
    # decrypts it back to plaintext on read. Non-deterministic by default
    # (a random IV per write - the same plaintext saved twice looks
    # completely different on disk, matching Rails' default and closing off
    # ciphertext-equality attacks). `deterministic: true` derives the IV
    # from HMAC(key, plaintext) instead, trading that guarantee away on
    # purpose so `Model.where(attribute: plaintext)` can still match - the
    # exact tradeoff ActiveRecord::Encryption documents for the same flag.
    module Encryption
      class Error < StandardError; end

      CIPHER_NAME = 'aes-256-gcm'.freeze
      IV_LENGTH = 12

      class << self
        # One shared secret for the whole app (Application#enable_attribute_
        # encryption sets this at boot, same spot as enable_sessions). A
        # single `encrypts ..., key: '...'` call can still override it per
        # attribute for a column that must rotate independently of the rest.
        attr_writer :primary_key

        def primary_key
          @primary_key
        end

        # Key rotation: retiring the shared application secret (a leak, a
        # scheduled rotation policy) does not have to mean every existing
        # ciphertext on disk becomes unreadable overnight. Old secrets keep
        # decrypting here (a column's writer always uses `primary_key`, so
        # any row that gets explicitly re-saved is re-encrypted under the
        # new one for free - there is no separate "encrypt" half to update).
        # A single `encrypts ..., previous_keys: [...]` call can override
        # this list per attribute instead, for a column whose OWN `key:`
        # rotates on a different schedule than the app-wide secret.
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

        # Tries the current key first (the common case, and the only one
        # that should ever be a cache hit); falls through the previous keys
        # in order only once that fails, so a value already re-encrypted
        # under the new key never pays for trying stale ones first. Raises
        # the ORIGINAL error from the current key once every key - current
        # and previous - has failed, not the last previous key's error,
        # since "wrong key" against the current key is the one message an
        # operator actually needs to see.
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
        # Superclass-plus-own fallback, same shape as Callbacks#callbacks_for
        # and Serialization#json_hidden_attributes - a plain `@ivar ||= {}`
        # per class would drop a base class's encrypted columns in every
        # subclass instead of inheriting them.
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

          # Non-deterministic encryption gives the same plaintext a fresh
          # random IV (hence different ciphertext bytes) every time it is
          # encrypted - so re-assigning the value a record already holds
          # would otherwise still overwrite @attributes with new ciphertext
          # and mark the attribute dirty for a change that never happened.
          # Comparing against the current plaintext first (public_send, not
          # self[], so it goes through this very reader and decrypts) makes
          # `model.attr = model.attr` a true no-op, matching plain columns.
          # A current value that fails to decrypt (corrupted on disk, or
          # mid-rotation past every known key) can't be compared at all -
          # rescue and fall through to a fresh write instead of blocking
          # every future assignment behind an unrelated read failure.
          define_method("#{attribute}=") do |value|
            begin
              return if value == public_send(attribute)
            rescue Encryption::Error
              nil
            end
            self[attribute] = Encryption.encrypt(self.class.encryption_key_for(attribute), value, deterministic: deterministic)
          end
        end

        # Keys are derived (PBKDF2, deliberately expensive) once per class
        # per attribute and cached - without this every single read/write of
        # an encrypted attribute would re-run PBKDF2 from scratch.
        def encryption_key_for(attribute)
          attribute = attribute.to_s
          @encryption_keys ||= {}
          @encryption_keys[attribute] ||= begin
            secret = encryption_config_for(attribute)[:key] || Encryption.primary_key
            raise Error, 'Prism::Orm::Encryption.primary_key= (or Application#enable_attribute_encryption) must be set before using `encrypts`, unless a key: is given' unless secret
            derive_encryption_key(attribute, secret)
          end
        end

        # Same PBKDF2-once-and-cache treatment as encryption_key_for, for the
        # retired secrets a rotated column still needs to be able to decrypt.
        # Falls back to the app-wide Encryption.previous_keys unless this
        # attribute named its own rotation schedule via `previous_keys:`.
        def encryption_previous_keys_for(attribute)
          attribute = attribute.to_s
          @encryption_previous_keys ||= {}
          @encryption_previous_keys[attribute] ||= begin
            secrets = encryption_config_for(attribute)[:previous_keys] || Encryption.previous_keys
            secrets.map { |secret| derive_encryption_key(attribute, secret) }
          end
        end

        # Lets ConditionNode translate `where(ssn: "123-45-6789")` into the
        # matching ciphertext, the same shape of problem Enum#enum_cast
        # already solves for Symbol labels. Refuses on a non-deterministic
        # column instead of silently building a condition that can never
        # match anything (a fresh random IV means encrypting the same
        # plaintext twice never produces the same ciphertext).
        #
        # Mid-rotation, a matching row may still be sitting on disk
        # encrypted under a previous key, so this returns every candidate
        # ciphertext (current key first) as an Array once previous_keys are
        # configured - ConditionNode's caller already treats an Array as an
        # IN-list (Predicates.evaluate), so a plain `where(ssn: plaintext)`
        # keeps finding not-yet-re-encrypted rows without callers needing to
        # know rotation is even happening. Returns a bare String (as before)
        # when there is nothing to rotate through, so the common case never
        # pays for the Array wrapping or an IN scan of one.
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
          MessageEncryptor.derive_key(secret, salt: "prism-orm-encryption/#{table_name}/#{attribute}")
        end
      end
    end
  end
end
