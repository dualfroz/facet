require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class OrmTokenForTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-token-for')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:token_for_users, %w[id email password_digest])

    Prism::Orm::TokenFor.primary_secret = 'primary-secret'
    Prism::Orm::TokenFor.previous_secrets = []

    user_class = Class.new(Prism::Orm::Model) do
      table_name :token_for_users
      has_secure_password
      generates_token_for(:password_reset, expires_in: 900) { password_digest }
      generates_token_for(:email_confirmation)
      # negative expires_in => already in the past the instant it is minted,
      # letting the expiry path be tested without stubbing the clock.
      generates_token_for(:already_expiring, expires_in: -1)
    end
    user_class.store = @store
    Object.const_set(:TokenForUser, user_class)

    @user = TokenForUser.create!(email: 'foksiu@example.com', password: 'hunter2')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :TokenForUser) if Object.const_defined?(:TokenForUser)
    Prism::Orm::TokenFor.primary_secret = nil
    Prism::Orm::TokenFor.previous_secrets = []
  end

  def test_token_round_trips_to_the_record
    token = @user.generate_token_for(:password_reset)
    found = TokenForUser.find_by_token_for(:password_reset, token)
    assert_equal @user.id, found&.id
  end

  def test_token_is_scoped_to_its_own_purpose
    token = @user.generate_token_for(:password_reset)
    assert_nil TokenForUser.find_by_token_for(:email_confirmation, token)
  end

  def test_expired_token_is_rejected
    token = @user.generate_token_for(:already_expiring)
    assert_nil TokenForUser.find_by_token_for(:already_expiring, token)
  end

  def test_token_invalidated_by_changing_fingerprint_after_generation
    token = @user.generate_token_for(:password_reset)
    @user.password = 'a completely different passphrase'
    @user.save!

    assert_nil TokenForUser.find_by_token_for(:password_reset, token)
  end

  def test_token_without_a_fingerprint_block_is_unaffected_by_record_changes
    token = @user.generate_token_for(:email_confirmation)
    @user.update!(email: 'someone-else@example.com')

    found = TokenForUser.find_by_token_for(:email_confirmation, token)
    assert_equal @user.id, found&.id
  end

  def test_garbage_token_is_rejected
    assert_nil TokenForUser.find_by_token_for(:password_reset, 'not-a-real-token')
    assert_nil TokenForUser.find_by_token_for(:password_reset, nil)
  end

  def test_token_for_a_deleted_record_no_longer_resolves
    token = @user.generate_token_for(:password_reset)
    @store.delete(:token_for_users, @user.id)

    assert_nil TokenForUser.find_by_token_for(:password_reset, token)
  end

  def test_unknown_purpose_raises
    assert_raises(Prism::Orm::TokenFor::Error) { @user.generate_token_for(:not_declared) }
    assert_raises(Prism::Orm::TokenFor::Error) { TokenForUser.find_by_token_for(:not_declared, 'x') }
  end

  def test_token_minted_under_a_retired_secret_still_verifies_after_rotation
    token = @user.generate_token_for(:email_confirmation)

    Prism::Orm::TokenFor.previous_secrets = ['primary-secret']
    Prism::Orm::TokenFor.primary_secret = 'rotated-secret'

    found = TokenForUser.find_by_token_for(:email_confirmation, token)
    assert_equal @user.id, found&.id
  end

  def test_token_cannot_be_replayed_across_two_unrelated_models
    @store.create_table(:token_for_widgets, %w[id name])
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :token_for_widgets
      generates_token_for(:password_reset, expires_in: 900)
    end
    widget_class.store = @store
    Object.const_set(:TokenForWidget, widget_class)

    token = @user.generate_token_for(:password_reset)
    assert_nil TokenForWidget.find_by_token_for(:password_reset, token)
  ensure
    Object.send(:remove_const, :TokenForWidget) if Object.const_defined?(:TokenForWidget)
  end
end
