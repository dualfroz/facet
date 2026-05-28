require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmValidationsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-validation-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:accounts, %w[id email nickname])
    account_class = Class.new(Prism::Orm::Model) do
      table_name :accounts
      validates :email, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
      validates :nickname, length: { minimum: 2, maximum: 10 }
    end
    account_class.store = @store
    Object.const_set(:Account, account_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Account) if Object.const_defined?(:Account)
  end

  def test_presence_validation_blocks_save
    account = Account.new(email: '')
    refute account.valid?
    assert_includes account.errors[:email], 'must be present'
  end

  def test_format_validation_rejects_bad_email
    account = Account.new(email: 'not-an-email', nickname: 'foksiu')
    refute account.valid?
    assert_includes account.errors[:email], 'is invalid'
  end

  def test_valid_record_has_no_errors
    account = Account.new(email: 'foksiu@example.com', nickname: 'foksiu')
    assert account.valid?
    assert_empty account.errors
  end

  def test_uniqueness_rejects_duplicate_email
    Account.create!(email: 'taken@example.com', nickname: 'first')
    dupe = Account.new(email: 'taken@example.com', nickname: 'second')
    refute dupe.valid?
    assert_includes dupe.errors[:email], 'must be unique'
  end

  def test_uniqueness_allows_saving_same_record_twice
    account = Account.create!(email: 'stable@example.com', nickname: 'stable')
    account.nickname = 'stable2'
    assert account.save, account.errors.full_messages.join(', ')
  end

  def test_length_validation
    account = Account.new(email: 'a@example.com', nickname: 'x')
    refute account.valid?
    assert_includes account.errors[:nickname], 'is too short (minimum 2)'
  end

  def test_custom_message
    Account.validates(:email, format: { with: /@/, message: 'needs an @ sign' })
    account = Account.new(email: 'nope', nickname: 'foksiu')
    refute account.valid?
    assert_includes account.errors[:email], 'needs an @ sign'
  ensure
    Account.validators.pop
  end
end
