require 'securerandom'

module Prism
  # Per-request masked CSRF tokens (the same scheme Rails uses): the raw
  # token lives in the session, but every rendered token is XORed with a
  # fresh random mask so two tokens issued to the same page never look
  # alike. That defeats BREACH-style compression oracles against a token
  # that would otherwise be a constant string embedded next to attacker-
  # influenced response bytes.
  class Csrf
    TOKEN_BYTES = 32
    SESSION_KEY = '_csrf_token'

    def initialize(session)
      @session = session
    end

    def raw_token
      @session[SESSION_KEY] ||= encode(SecureRandom.random_bytes(TOKEN_BYTES))
    end

    def masked_token
      mask = SecureRandom.random_bytes(TOKEN_BYTES)
      masked = xor(decode(raw_token), mask)
      encode(mask + masked)
    end

    def valid_token?(token)
      return false if token.nil? || token.empty?
      decoded = decode(token)
      return false unless decoded && decoded.bytesize == TOKEN_BYTES * 2
      mask = decoded.byteslice(0, TOKEN_BYTES)
      masked = decoded.byteslice(TOKEN_BYTES, TOKEN_BYTES)
      secure_compare(xor(masked, mask), decode(raw_token))
    rescue ArgumentError
      false
    end

    private

    def xor(left, right)
      left.bytes.zip(right.bytes).map { |a, b| a ^ b }.pack('C*')
    end

    def encode(bytes)
      [bytes].pack('m0').tr('+/', '-_').delete('=')
    end

    def decode(text)
      restored = text.tr('-_', '+/')
      padding = (4 - restored.bytesize % 4) % 4
      (restored + ('=' * padding)).unpack1('m0')
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
