require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmSecurePasswordTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-secure-password-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:accounts, %w[id email password_digest pin_digest])
    account_class = Class.new(Prism::Orm::Model) do
      table_name :accounts
      validates :email, presence: true
      has_secure_password
      has_secure_password :pin, validations: false
    end
    account_class.store = @store
    Object.const_set(:SecureAccount, account_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :SecureAccount) if Object.const_defined?(:SecureAccount)
  end

  def test_setting_password_populates_the_digest_column
    account = SecureAccount.new(email: 'a@b.com', password: 'hunter2')
    refute_nil account[:password_digest]
    refute_equal 'hunter2', account[:password_digest]
  end

  def test_authenticate_returns_the_record_on_a_correct_password
    account = SecureAccount.create!(email: 'a@b.com', password: 'hunter2')
    assert_equal account, account.authenticate('hunter2')
  end

  def test_authenticate_returns_false_on_a_wrong_password
    account = SecureAccount.create!(email: 'a@b.com', password: 'hunter2')
    refute account.authenticate('wrong')
  end

  def test_authenticate_returns_false_when_no_password_was_ever_set
    account = SecureAccount.new(email: 'a@b.com')
    account[:password_digest] = nil
    refute account.authenticate('anything')
  end

  def test_two_digests_from_the_same_password_are_different_but_both_verify
    first = Prism::Orm::SecurePassword.digest('hunter2')
    second = Prism::Orm::SecurePassword.digest('hunter2')
    refute_equal first, second
    assert Prism::Orm::SecurePassword.verify(first, 'hunter2')
    assert Prism::Orm::SecurePassword.verify(second, 'hunter2')
  end

  def test_presence_validation_requires_a_password_on_create
    account = SecureAccount.new(email: 'a@b.com')
    refute account.valid?
    assert_includes account.errors[:password], 'must be present'
  end

  def test_confirmation_mismatch_is_rejected
    account = SecureAccount.new(email: 'a@b.com', password: 'hunter2', password_confirmation: 'other')
    refute account.valid?
    assert_includes account.errors[:password], "doesn't match confirmation"
  end

  def test_confirmation_match_is_accepted
    account = SecureAccount.new(email: 'a@b.com', password: 'hunter2', password_confirmation: 'hunter2')
    assert account.valid?
  end

  def test_updating_an_already_persisted_record_without_touching_the_password_keeps_it_valid
    account = SecureAccount.create!(email: 'a@b.com', password: 'hunter2')
    account.update!(email: 'new@b.com')
    assert account.authenticate('hunter2')
  end

  def test_custom_attribute_name_defines_its_own_authenticate_method
    account = SecureAccount.create!(email: 'a@b.com', password: 'hunter2', pin: '1234')
    assert_equal account, account.authenticate_pin('1234')
    refute account.authenticate_pin('0000')
  end
end
