module Prism
  # Ties MessageVerifier/MessageEncryptor to a request/response pair so
  # controllers can read and write tamper-evident or fully opaque cookies
  # without touching OpenSSL directly.
  class CookieJar
    # `previous_secrets:` gives cookies.signed/cookies.encrypted the same
    # rotation contract as Application#enable_attribute_encryption and
    # Prism::Session: a cookie written under a retired secret still reads
    # back, a fresh #[]= write always signs/encrypts under `secret`.
    def initialize(request, response, secret:, previous_secrets: [])
      @request = request
      @response = response
      @verifier = MessageVerifier.new(secret)
      @encryptor = MessageEncryptor.new(MessageEncryptor.derive_key(secret))
      @previous_verifiers = previous_secrets.map { |previous| MessageVerifier.new(previous) }
      @previous_encryptors = previous_secrets.map { |previous| MessageEncryptor.new(MessageEncryptor.derive_key(previous)) }
    end

    def [](name)
      @request.cookies[name.to_s]
    end

    def []=(name, value_or_options)
      value, options = self.class.split_value(value_or_options)
      set(name, value, options)
    end

    def set(name, value, options = {})
      @response.set_cookie(name, value.to_s, options)
    end

    def signed
      @signed ||= Accessor.new(self, @verifier, :generate, :verified, fallback_codecs: @previous_verifiers)
    end

    def encrypted
      @encrypted ||= Accessor.new(self, @encryptor, :encrypt_and_sign, :decrypt_and_verify_safe, fallback_codecs: @previous_encryptors)
    end

    def self.split_value(value_or_options)
      if value_or_options.is_a?(Hash) && value_or_options.key?(:value)
        options = value_or_options.dup
        [options.delete(:value), options]
      else
        [value_or_options, {}]
      end
    end

    class Accessor
      def initialize(jar, codec, encode_method, decode_method, fallback_codecs: [])
        @jar = jar
        @codec = codec
        @encode_method = encode_method
        @decode_method = decode_method
        @fallback_codecs = fallback_codecs
      end

      def [](name)
        raw = @jar[name]
        return nil if raw.nil?
        decoded = @codec.public_send(@decode_method, raw)
        return decoded unless decoded.nil?
        @fallback_codecs.each do |codec|
          decoded = codec.public_send(@decode_method, raw)
          return decoded unless decoded.nil?
        end
        nil
      end

      def []=(name, value_or_options)
        value, options = CookieJar.split_value(value_or_options)
        @jar.set(name, @codec.public_send(@encode_method, value), options)
      end
    end
  end

  class MessageEncryptor
    def decrypt_and_verify_safe(message)
      decrypt_and_verify(message)
    rescue InvalidMessage
      nil
    end
  end
end
