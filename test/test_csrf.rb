require 'minitest/autorun'
require 'prism'

class CsrfTest < Minitest::Test
  def setup
    @session = {}
    @csrf = Prism::Csrf.new(@session)
  end

  def test_raw_token_is_persisted_in_session
    token = @csrf.raw_token
    assert_equal token, @session[Prism::Csrf::SESSION_KEY]
  end

  def test_raw_token_is_stable_across_calls
    assert_equal @csrf.raw_token, @csrf.raw_token
  end

  def test_masked_token_differs_each_call
    refute_equal @csrf.masked_token, @csrf.masked_token
  end

  def test_masked_token_is_valid
    assert @csrf.valid_token?(@csrf.masked_token)
  end

  def test_multiple_masked_tokens_from_same_raw_token_all_validate
    tokens = Array.new(5) { @csrf.masked_token }
    assert tokens.all? { |token| @csrf.valid_token?(token) }
    assert_equal 5, tokens.uniq.size
  end

  def test_token_from_different_session_is_rejected
    other_session = {}
    other_csrf = Prism::Csrf.new(other_session)
    refute @csrf.valid_token?(other_csrf.masked_token)
  end

  def test_blank_or_garbage_tokens_are_rejected
    refute @csrf.valid_token?(nil)
    refute @csrf.valid_token?('')
    refute @csrf.valid_token?('not-base64!!!')
    refute @csrf.valid_token?('dGhpcyBpcyB0b28gc2hvcnQ=')
  end

  def test_tampering_with_masked_token_invalidates_it
    masked = @csrf.masked_token
    tampered = masked.sub(/.\z/) { |c| c == 'a' ? 'b' : 'a' }
    refute @csrf.valid_token?(tampered)
  end
end
