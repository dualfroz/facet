module Facet
  class MessageVerifier
    class InvalidSignature < StandardError; end

    def initialize(secret, digest: 'SHA256', serializer: JSON)
      raise ArgumentError, 'secret must be present' if secret.nil? || secret.to_s.empty?
      @secret = secret.to_s
      @digest = digest
      @serializer = serializer
    end

    def generate(value, options = {})
      exp = options[:expires_at] || (options[:expires_in] ? Time.now.utc + options[:expires_in] : nil)
      payload = wrap(value, exp, options[:purpose])
      data = encode(@serializer.dump(payload))
      "#{data}--#{digest_for(data)}"
    end

    def verify(signed, purpose: nil)
      raise InvalidSignature, 'invalid message' unless valid_message?(signed)
      data, = signed.split('--', 2)
      unwrap(@serializer.load(decode(data)), purpose)
    rescue ArgumentError, TypeError
      raise InvalidSignature, 'invalid message'
    end

    def verified(signed, purpose: nil)
      verify(signed, purpose: purpose)
    rescue InvalidSignature
      nil
    end

    def valid_message?(signed)
      return false if signed.nil? || !signed.include?('--')
      data, signature = signed.split('--', 2)
      return false if data.nil? || data.empty? || signature.nil? || signature.empty?
      secure_compare(signature, digest_for(data))
    end

    private

    ENVELOPE_KEY = '_facet_envelope'

    def wrap(value, exp, purpose)
      return value if exp.nil? && purpose.nil?
      { ENVELOPE_KEY => true, 'value' => value, 'exp' => exp&.utc&.iso8601, 'pur' => purpose&.to_s }
    end

    def unwrap(payload, purpose)
      unless payload.is_a?(Hash) && payload[ENVELOPE_KEY]
        raise InvalidSignature, 'message requires a purpose' if purpose
        return payload
      end
      raise InvalidSignature, 'message expired' if payload['exp'] && Time.parse(payload['exp']) <= Time.now.utc
      raise InvalidSignature, 'purpose mismatch' unless payload['pur'] == purpose&.to_s
      payload['value']
    end

    def digest_for(data)
      OpenSSL::HMAC.hexdigest(@digest, @secret, data)
    end

    def encode(text)
      [text].pack('m0')
    end

    def decode(text)
      text.unpack1('m0')
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize
      left_bytes = left.unpack("C#{left.bytesize}")
      difference = 0
      right.each_byte.with_index { |byte, index| difference |= byte ^ left_bytes[index] }
      difference.zero?
    end
  end
end
