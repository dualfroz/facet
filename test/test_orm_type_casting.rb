require 'minitest/autorun'
require 'facet'

class OrmTypeCastingTest < Minitest::Test
  Cast = Facet::Orm::TypeCasting

  def test_nil_stays_nil_for_every_type
    %i[string text integer float boolean datetime].each do |type|
      assert_nil Cast.cast(type, nil), "expected nil to survive :#{type}"
    end
  end

  def test_unknown_type_raises_argument_error
    assert_raises(ArgumentError) { Cast.cast(:money, '5') }
  end

  def test_string_and_text_stringify_non_strings
    assert_equal '5', Cast.cast(:string, 5)
    assert_equal '5', Cast.cast(:text, 5)
    assert_equal 'already', Cast.cast(:string, 'already')
  end

  def test_integer_parses_numeric_strings
    assert_equal 42, Cast.cast(:integer, '42')
    assert_equal(-3, Cast.cast(:integer, '-3'))
    assert_equal 7, Cast.cast(:integer, ' 7 ')
  end

  def test_integer_passes_through_actual_integers_and_numerics
    assert_equal 42, Cast.cast(:integer, 42)
    assert_equal 3, Cast.cast(:integer, 3.9)
  end

  def test_integer_blank_string_is_nil_not_zero
    assert_nil Cast.cast(:integer, '')
    assert_nil Cast.cast(:integer, '   ')
  end

  def test_integer_garbage_raises_invalid_cast
    error = assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Cast.cast(:integer, 'abc') }
    assert_match(/abc/, error.message)
  end

  def test_integer_rejects_float_looking_strings
    assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Cast.cast(:integer, '4.5') }
  end

  def test_float_parses_numeric_strings
    assert_in_delta 4.5, Cast.cast(:float, '4.5')
    assert_in_delta 4.0, Cast.cast(:float, '4')
  end

  def test_float_blank_string_is_nil
    assert_nil Cast.cast(:float, '')
  end

  def test_float_garbage_raises_invalid_cast
    assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Cast.cast(:float, 'nope') }
  end

  def test_boolean_recognizes_common_true_strings
    %w[1 t true y yes on TRUE Yes On].each do |value|
      assert_equal true, Cast.cast(:boolean, value), "expected #{value.inspect} to cast true"
    end
  end

  def test_boolean_recognizes_common_false_strings
    %w[0 f false n no off FALSE No Off].each do |value|
      assert_equal false, Cast.cast(:boolean, value), "expected #{value.inspect} to cast false"
    end
  end

  def test_boolean_passes_through_actual_booleans
    assert_equal true, Cast.cast(:boolean, true)
    assert_equal false, Cast.cast(:boolean, false)
  end

  def test_boolean_garbage_raises_invalid_cast_instead_of_guessing_truthy
    error = assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Cast.cast(:boolean, 'banana') }
    assert_match(/banana/, error.message)
  end

  def test_datetime_passes_through_time
    now = Time.now
    assert_same now, Cast.cast(:datetime, now)
  end

  def test_datetime_parses_iso8601_strings
    result = Cast.cast(:datetime, '2026-01-15T10:30:00Z')
    assert_kind_of Time, result
    assert_equal 2026, result.year
    assert_equal 1, result.month
    assert_equal 15, result.day
  end

  def test_datetime_converts_date
    result = Cast.cast(:datetime, Date.new(2026, 3, 4))
    assert_kind_of Time, result
    assert_equal 2026, result.year
    assert_equal 3, result.month
    assert_equal 4, result.day
  end

  def test_datetime_garbage_raises_invalid_cast
    assert_raises(Facet::Orm::TypeCasting::InvalidCast) { Cast.cast(:datetime, 'not a date') }
  end
end
