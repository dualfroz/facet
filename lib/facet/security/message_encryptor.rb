module Facet
  class MessageEncryptor
    class InvalidMessage < StandardError; end

    CIPHER_NAME = 'aes-256-gcm'.freeze
    KEY_LENGTH = 32

    def self.derive_key(secret, salt: 'facet-message-encryptor', length: KEY_LENGTH)
      OpenSSL::PKCS5.pbkdf2_hmac(secret.to_s, salt.to_s, 2 ** 16, length, OpenSSL::Digest.new('SHA256'))
    end

    def initialize(key, serializer: JSON)
      raise ArgumentError, "key must be #{KEY_LENGTH} bytes, got #{key.bytesize}" unless key.bytesize == KEY_LENGTH
      @key = key
      @serializer = serializer
    end

    def encrypt_and_sign(value)
      cipher = new_cipher(:encrypt)
      iv = cipher.random_iv
      cipher.auth_data = ''
      plaintext = @serializer.dump(value)
      encrypted = cipher.update(plaintext) + cipher.final
      [encode(encrypted), encode(iv), encode(cipher.auth_tag)].join('--')
    end

    def decrypt_and_verify(message)
      encrypted, iv, auth_tag = message.to_s.split('--', 3)
      raise InvalidMessage, 'invalid message' if [encrypted, iv, auth_tag].any?(&:nil?)

      cipher = new_cipher(:decrypt)
      cipher.iv = decode(iv)
      cipher.auth_tag = decode(auth_tag)
      cipher.auth_data = ''
      decrypted = cipher.update(decode(encrypted)) + cipher.final
      @serializer.load(decrypted)
    rescue OpenSSL::Cipher::CipherError, ArgumentError, TypeError
      raise InvalidMessage, 'invalid message'
    end

    private

    def new_cipher(mode)
      cipher = OpenSSL::Cipher.new(CIPHER_NAME)
      cipher.public_send(mode)
      cipher.key = @key
      cipher
    end

    def encode(bytes)
      [bytes].pack('m0')
    end

    def decode(text)
      text.unpack1('m0')
    end
  end
end
