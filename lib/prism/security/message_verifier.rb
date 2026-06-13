module Prism
  # Signs arbitrary serializable values with an HMAC so tampering can be
  # detected on the way back in (query strings, cookies, hidden form
  # fields). This does not hide the payload - see MessageEncryptor for that.
  class MessageVerifier
    class InvalidSignature < StandardError; end

    def initialize(secret, digest: 'SHA256', serializer: JSON)
      raise ArgumentError, 'secret must be present' if secret.nil? || secret.to_s.empty?
      @secret = secret.to_s
      @digest = digest
      @serializer = serializer
    end

    # `expires_in`/`expires_at` and `purpose` mirror Rails' MessageVerifier:
    # a link generated with `purpose: 'cover_download'` fails #verify for
    # any other purpose (or none), and a link past its expiry fails #verify
    # the same way a tampered signature would - both close over the exact
    # same InvalidSignature the caller already has to handle, so a
    # controller cannot accidentally forget to check them separately.
    # Omitting both keeps the plain envelope-free format earlier callers
    # (CookieJar, Csrf) already rely on - this is additive, not a format
    # bump, so it never breaks a signed value already in flight.
    #
    # `options` is a plain trailing Hash, not real keyword arguments, on
    # purpose: every existing caller in this codebase (and the tests below)
    # calls `generate('user_id' => 1)` - a bareword Hash AS the value being
    # signed, no braces. Ruby's parser treats that call-site shape as
    # keyword syntax regardless of the callee's actual parameter names, so
    # declaring real `expires_in:`/`purpose:` keywords here would make
    # every one of those calls raise "wrong number of arguments (given 0,
    # expected 1)" instead of signing the hash - proven by hand before this
    # method existed in this shape.
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

    ENVELOPE_KEY = '_prism_envelope'

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
