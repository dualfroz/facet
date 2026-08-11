require 'minitest/autorun'
require 'prism'
require 'tmpdir'

# Regression coverage for a real bug found while wiring `encrypts` into
# examples/blog's User#email: every validator in Validatable read the raw
# stored value through `self[attribute]` instead of the attribute's own
# reader method. For a plain column that is the same value either way, so
# the bug was invisible until a column had a reader that DIFFERS from raw
# storage - exactly what `encrypts` defines (decrypts on read, and
# deterministic columns re-encrypt on query). Two concrete failures this
# caused before the fix:
#   1. `format`/`length`/`inclusion` validators matched the CIPHERTEXT,
#      not the plaintext the user typed - a syntactically valid email was
#      rejected as "invalid" (ciphertext never contains '@').
#   2. `uniqueness` built `where(attribute => ciphertext)`, and
#      ConditionNode's deterministic-encryption cast re-encrypts whatever
#      it is given - so the already-ciphertext value got encrypted AGAIN,
#      never matching the single-encrypted value already on disk. Two
#      records with the IDENTICAL plaintext silently passed uniqueness.
class OrmValidatesEncryptedAttributeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-validates-encrypted-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:contacts, %w[id email])
    Prism::Orm::Encryption.primary_key = 'test-primary-key-do-not-use-in-prod'

    contact_class = Class.new(Prism::Orm::Model) do
      table_name :contacts
      encrypts :email, deterministic: true
      validates :email, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
    end
    contact_class.store = @store
    Object.const_set(:EncryptedContact, contact_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Prism::Orm::Encryption.primary_key = nil
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
