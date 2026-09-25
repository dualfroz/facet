require 'minitest/autorun'
require 'facet'

class MessageEncryptorTest < Minitest::Test
  def setup
    @key = Facet::MessageEncryptor.derive_key('super-secret-app-key')
    @encryptor = Facet::MessageEncryptor.new(@key)
  end

  def test_derived_key_has_correct_length
    assert_equal 32, @key.bytesize
  end

  def test_derive_key_is_deterministic_for_same_secret_and_salt
    assert_equal @key, Facet::MessageEncryptor.derive_key('super-secret-app-key')
  end

  def test_derive_key_differs_per_salt
    other = Facet::MessageEncryptor.derive_key('super-secret-app-key', salt: 'other-salt')
    refute_equal @key, other
  end

  def test_round_trips_a_hash
    token = @encryptor.encrypt_and_sign('admin' => true, 'user_id' => 7)
    assert_equal({ 'admin' => true, 'user_id' => 7 }, @encryptor.decrypt_and_verify(token))
  end

  def test_ciphertext_does_not_contain_plaintext
    token = @encryptor.encrypt_and_sign('super-secret-value-xyz')
    refute_includes token, 'super-secret-value-xyz'
  end

  def test_two_encryptions_of_same_value_differ
    first = @encryptor.encrypt_and_sign('same value')
    second = @encryptor.encrypt_and_sign('same value')
    refute_equal first, second
  end

  def test_tampered_ciphertext_fails_to_decrypt
    token = @encryptor.encrypt_and_sign('user_id' => 1)
    encrypted, iv, tag = token.split('--', 3)
    tampered = "#{encrypted}AA--#{iv}--#{tag}"
    assert_raises(Facet::MessageEncryptor::InvalidMessage) { @encryptor.decrypt_and_verify(tampered) }
  end

  def test_wrong_key_cannot_decrypt
    token = @encryptor.encrypt_and_sign('user_id' => 1)
    other = Facet::MessageEncryptor.new(Facet::MessageEncryptor.derive_key('a-completely-different-key'))
    assert_raises(Facet::MessageEncryptor::InvalidMessage) { other.decrypt_and_verify(token) }
  end

  def test_malformed_message_raises
    assert_raises(Facet::MessageEncryptor::InvalidMessage) { @encryptor.decrypt_and_verify('garbage') }
  end

  def test_rejects_key_of_wrong_length
    assert_raises(ArgumentError) { Facet::MessageEncryptor.new('too-short') }
  end
end
