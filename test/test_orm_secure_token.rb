require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmSecureTokenTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-secure-token-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:api_keys, %w[id name token auth_token])
    api_key_class = Class.new(Prism::Orm::Model) do
      table_name :api_keys
      has_secure_token
      has_secure_token :auth_token, length: 6
    end
    api_key_class.store = @store
    Object.const_set(:SecureTokenKey, api_key_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :SecureTokenKey) if Object.const_defined?(:SecureTokenKey)
  end

  def test_token_is_generated_on_create
    key = SecureTokenKey.create!(name: 'ci')
    refute_nil key.token
    refute_empty key.token
  end

  def test_two_records_get_different_tokens
    first = SecureTokenKey.create!(name: 'a')
    second = SecureTokenKey.create!(name: 'b')
    refute_equal first.token, second.token
  end

  def test_an_explicitly_assigned_token_is_kept_on_create
    key = SecureTokenKey.create!(name: 'ci', token: 'my-own-token')
    assert_equal 'my-own-token', key.token
  end

  def test_token_survives_a_reload
    key = SecureTokenKey.create!(name: 'ci')
    token = key.token
    reloaded = SecureTokenKey.find(key.id)
    assert_equal token, reloaded.token
  end

  def test_regenerate_bang_persists_a_new_token
    key = SecureTokenKey.create!(name: 'ci')
    original = key.token
    key.regenerate_token!
    refute_equal original, key.token
    assert_equal key.token, SecureTokenKey.find(key.id).token
  end

  def test_second_attribute_on_the_same_model_gets_its_own_independent_token
    key = SecureTokenKey.create!(name: 'ci')
    refute_equal key.token, key.auth_token
    original_auth_token = key.auth_token
    key.regenerate_token!
    assert_equal original_auth_token, key.auth_token
  end

  def test_generate_produces_a_urlsafe_string_of_the_requested_byte_length
    token = Prism::Orm::SecureToken.generate(6)
    assert_match(/\A[A-Za-z0-9_-]+\z/, token)
  end

  def test_secure_token_attributes_lists_every_declared_attribute
    assert_equal %i[token auth_token], SecureTokenKey.secure_token_attributes
  end
end
