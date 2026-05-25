module Prism
  module Session
    Separator = '--'.freeze

    module_function

    def encode(hash, secret)
      payload = encode64(JSON.generate(hash))
      "#{payload}#{Separator}#{sign(payload, secret)}"
    end

    def decode(cookie, secret)
      return {} if cookie.nil? || cookie.empty?
      payload, signature = cookie.split(Separator, 2)
      return {} if payload.nil? || signature.nil?
      return {} unless secure_compare(signature, sign(payload, secret))
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
