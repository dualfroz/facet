require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmValidatesEncryptedAttributeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-validates-encrypted-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:contacts, %w[id email])
    Facet::Orm::Encryption.primary_key = 'test-primary-key-do-not-use-in-prod'

    contact_class = Class.new(Facet::Orm::Model) do
      table_name :contacts
      encrypts :email, deterministic: true
      validates :email, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
    end
    contact_class.store = @store
    Object.const_set(:EncryptedContact, contact_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Facet::Orm::Encryption.primary_key = nil
    Object.send(:remove_const, :EncryptedContact) if Object.const_defined?(:EncryptedContact)
  end

  def test_format_validation_checks_the_decrypted_plaintext_not_the_ciphertext
    contact = EncryptedContact.new(email: 'alice@example.com')
    assert contact.valid?, "expected a well-formed plaintext email to pass format validation, got: #{contact.errors.full_messages}"
  end

  def test_format_validation_still_rejects_a_genuinely_malformed_plaintext
    contact = EncryptedContact.new(email: 'not-an-email')
    refute contact.valid?
    assert_includes contact.errors.full_messages.join, 'invalid'
  end

  def test_uniqueness_catches_a_real_duplicate_plaintext_behind_deterministic_encryption
    EncryptedContact.create!(email: 'bob@example.com')
    duplicate = EncryptedContact.new(email: 'bob@example.com')
    refute duplicate.valid?, 'expected the second record with the same plaintext email to fail uniqueness'
    assert_includes duplicate.errors.full_messages.join, 'unique'
  end

  def test_uniqueness_allows_a_genuinely_different_plaintext
    EncryptedContact.create!(email: 'carol@example.com')
    other = EncryptedContact.new(email: 'dave@example.com')
    assert other.valid?, "expected a different plaintext email to pass uniqueness, got: #{other.errors.full_messages}"
  end

  def test_the_stored_column_is_still_ciphertext_despite_validation_seeing_plaintext
    contact = EncryptedContact.create!(email: 'erin@example.com')
    raw_row = @store.find(:contacts, contact.id)
    refute_equal 'erin@example.com', raw_row['email']
    refute_includes raw_row['email'], '@'
  end
end
