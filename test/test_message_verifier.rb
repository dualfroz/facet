require 'minitest/autorun'
require 'prism'

class MessageVerifierTest < Minitest::Test
  def setup
    @verifier = Prism::MessageVerifier.new('s3cr3t')
  end

  def test_round_trips_a_hash
    signed = @verifier.generate('user_id' => 42)
    assert_equal({ 'user_id' => 42 }, @verifier.verify(signed))
  end

  def test_round_trips_a_string
    signed = @verifier.generate('hello world')
    assert_equal 'hello world', @verifier.verify(signed)
  end

  def test_tampered_payload_is_rejected
    signed = @verifier.generate('user_id' => 1)
    data, signature = signed.split('--', 2)
    tampered = "#{data}x--#{signature}"
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(tampered) }
  end

  def test_tampered_signature_is_rejected
    signed = @verifier.generate('user_id' => 1)
    data, = signed.split('--', 2)
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify("#{data}--deadbeef") }
  end

  def test_wrong_secret_cannot_verify
    signed = @verifier.generate('user_id' => 1)
    other = Prism::MessageVerifier.new('different-secret')
    assert_raises(Prism::MessageVerifier::InvalidSignature) { other.verify(signed) }
  end

  def test_malformed_message_is_rejected
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify('not-a-signed-message') }
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(nil) }
  end

  def test_verified_returns_nil_instead_of_raising
    assert_nil @verifier.verified('garbage')
  end

  def test_blank_secret_is_rejected
    assert_raises(ArgumentError) { Prism::MessageVerifier.new('') }
    assert_raises(ArgumentError) { Prism::MessageVerifier.new(nil) }
  end

  def test_expires_at_in_the_future_still_verifies
    signed = @verifier.generate({ 'id' => 1 }, expires_at: Time.now.utc + 60)
    assert_equal({ 'id' => 1 }, @verifier.verify(signed))
  end

  def test_expires_at_in_the_past_is_rejected
    signed = @verifier.generate({ 'id' => 1 }, expires_at: Time.now.utc - 1)
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(signed) }
  end

  def test_expires_in_computes_expires_at_from_now
    signed = @verifier.generate('hello', expires_in: 10)
    assert_equal 'hello', @verifier.verify(signed)
  end

  def test_expired_message_does_not_survive_tampering_style_verification
    signed = @verifier.generate('hello', expires_in: -1)
    assert_nil @verifier.verified(signed)
  end

  def test_purpose_must_match_on_verify
    signed = @verifier.generate('secret-token', purpose: 'password_reset')
    assert_equal 'secret-token', @verifier.verify(signed, purpose: 'password_reset')
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(signed, purpose: 'email_confirmation') }
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(signed) }
  end

  def test_purposeless_message_rejected_when_a_purpose_is_required
    signed = @verifier.generate('plain')
    assert_raises(Prism::MessageVerifier::InvalidSignature) { @verifier.verify(signed, purpose: 'password_reset') }
  end

  def test_purpose_accepts_symbol_or_string_interchangeably
    signed = @verifier.generate('value', purpose: :password_reset)
    assert_equal 'value', @verifier.verify(signed, purpose: 'password_reset')
  end

  def test_plain_generate_still_round_trips_without_envelope_overhead
    signed = @verifier.generate('user_id' => 1)
    refute_includes decode_payload(signed).keys, '_prism_envelope'
  end

  private

  def decode_payload(signed)
    data, = signed.split('--', 2)
    JSON.parse(data.unpack1('m0'))
  end
end
