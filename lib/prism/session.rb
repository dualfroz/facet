module Prism
  module Session
    Separator = '--'.freeze

    module_function

    def encode(hash, secret)
      payload = encode64(JSON.generate(hash))
      "#{payload}#{Separator}#{sign(payload, secret)}"
    end

    # `previous_secrets:` lets an app rotate its session secret (the
    # Middleware::Session equivalent of Application#enable_attribute_
    # encryption's `previous_secrets:`) without logging out every signed-in
    # user the moment it deploys: a cookie signed under any retired secret
    # still decodes here, while #encode (called once per request that
    # touches the session) always signs under the current one, so every
    # session is transparently re-signed onto the new secret the next time
    # it changes at all.
    def decode(cookie, secret, previous_secrets: [])
      return {} if cookie.nil? || cookie.empty?
      payload, signature = cookie.split(Separator, 2)
      return {} if payload.nil? || signature.nil?
      candidates = [secret, *previous_secrets]
      return {} unless candidates.any? { |candidate| secure_compare(signature, sign(payload, candidate)) }
      JSON.parse(decode64(payload))
    rescue JSON::ParserError, ArgumentError
      {}
    end

    def sign(payload, secret)
      OpenSSL::HMAC.hexdigest('SHA256', secret, payload)
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
      difference.zero?
    end

    def encode64(text)
      [text].pack('m0').tr('+/', '-_').delete('=')
    end

    def decode64(text)
      restored = text.tr('-_', '+/')
      padding = (4 - restored.bytesize % 4) % 4
      (restored + ('=' * padding)).unpack1('m0')
    end
  end
end
