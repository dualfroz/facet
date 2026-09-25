require 'minitest/autorun'
require 'facet'

class I18nTranslatorTest < Minitest::Test
  def setup
    @backend = Facet::I18n::Backend.new
    @backend.store_translations(:en, {
      'greeting' => 'Hello, %{name}!',
      'apples' => { 'zero' => 'no apples', 'one' => 'one apple', 'other' => '%{count} apples' },
      'cars' => { 'one' => 'one car', 'other' => '%{count} cars' },
      'nav' => { 'home' => 'Home' }
    })
    @backend.store_translations(:pl, 'nav' => { 'home' => 'Strona glowna' })
    @translator = Facet::I18n::Translator.new(@backend, default_locale: :en)
  end

  def test_translate_plain_string
    assert_equal 'Home', @translator.translate('nav.home', locale: :en)
  end

  def test_translate_interpolates_named_placeholders
    assert_equal 'Hello, Ada!', @translator.translate('greeting', locale: :en, name: 'Ada')
  end

  def test_translate_missing_interpolation_argument_raises
    assert_raises(Facet::I18n::Translator::MissingInterpolationError) do
      @translator.translate('greeting', locale: :en)
    end
  end

  def test_translate_missing_key_raises_by_default
    assert_raises(Facet::I18n::Translator::MissingTranslationError) do
      @translator.translate('nowhere.at.all', locale: :en)
    end
  end

  def test_translate_missing_key_uses_default_when_given
    assert_equal 'fallback text', @translator.translate('nowhere.at.all', locale: :en, default: 'fallback text')
  end

  def test_translate_pluralizes_zero_one_other
    assert_equal 'no apples', @translator.translate('apples', locale: :en, count: 0)
    assert_equal 'one apple', @translator.translate('apples', locale: :en, count: 1)
    assert_equal '5 apples', @translator.translate('apples', locale: :en, count: 5)
  end

  def test_translate_pluralizes_zero_as_other_when_no_zero_key
    assert_equal '0 cars', @translator.translate('cars', locale: :en, count: 0)
  end

  def test_translate_falls_back_to_default_locale_for_missing_key_in_requested_locale
    assert_equal 'Hello, Ada!', @translator.translate('greeting', locale: :pl, name: 'Ada')
  end

  def test_translate_prefers_requested_locale_over_fallback
    assert_equal 'Strona glowna', @translator.translate('nav.home', locale: :pl)
  end

  def test_custom_fallback_chain_is_tried_before_default_locale
    backend = Facet::I18n::Backend.new
    backend.store_translations(:en, 'only_en' => 'English only')
    backend.store_translations(:'pt-BR', 'greeting' => 'Ola')
    translator = Facet::I18n::Translator.new(backend, default_locale: :en, fallbacks: { pt: [:'pt-BR'] })
    assert_equal 'Ola', translator.translate('greeting', locale: :pt)
  end

  def test_localize_time_with_default_format
    time = Time.utc(2026, 3, 5, 8, 30, 0)
    assert_equal '2026-03-05 08:30:00', @translator.localize(time, locale: :en)
  end

  def test_localize_date_with_default_format
    date = Date.new(2026, 3, 5)
    assert_equal '2026-03-05', @translator.localize(date, locale: :en)
  end

  def test_localize_uses_named_format_from_backend
    @backend.store_translations(:en, 'time' => { 'formats' => { 'short' => '%d.%m.%Y' } })
    time = Time.utc(2026, 3, 5, 8, 30, 0)
    assert_equal '05.03.2026', @translator.localize(time, locale: :en, format: :short)
  end
end
