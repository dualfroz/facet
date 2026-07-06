require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class I18nModuleTest < Minitest::Test
  def setup
    Prism::I18n.reset!
    Prism::I18n.store_translations(:en, 'hello' => 'Hello')
    Prism::I18n.store_translations(:pl, 'hello' => 'Czesc')
  end

  def teardown
    Prism::I18n.reset!
  end

  def test_default_locale_is_en_out_of_the_box
    assert_equal :en, Prism::I18n.default_locale
  end

  def test_locale_reads_and_writes_current_locale
    assert_equal :en, Prism::I18n.locale
    Prism::I18n.locale = :pl
    assert_equal :pl, Prism::I18n.locale
  end

  def test_t_and_l_are_aliases
    assert_equal Prism::I18n.translate('hello', locale: :en), Prism::I18n.t('hello', locale: :en)
    time = Time.utc(2026, 1, 1)
    assert_equal Prism::I18n.localize(time, locale: :en), Prism::I18n.l(time, locale: :en)
  end

  def test_translate_uses_current_locale_by_default
    Prism::I18n.locale = :pl
    assert_equal 'Czesc', Prism::I18n.t('hello')
  end

  def test_with_locale_is_scoped_and_restores_previous_value
    Prism::I18n.locale = :en
    Prism::I18n.with_locale(:pl) do
      assert_equal 'Czesc', Prism::I18n.t('hello')
    end
    assert_equal :en, Prism::I18n.locale
  end

  def test_with_locale_nests_correctly
    Prism::I18n.with_locale(:en) do
      Prism::I18n.with_locale(:pl) do
        assert_equal :pl, Prism::I18n.locale
      end
      assert_equal :en, Prism::I18n.locale
    end
  end

  def test_available_locales_reflects_stored_translations
    assert_equal [:en, :pl], Prism::I18n.available_locales.sort
  end

  def test_load_translations_reads_every_json_file_under_load_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'fr.json'), '{"hello": "Bonjour"}')
      Prism::I18n.load_path << dir
      Prism::I18n.load_translations!
      assert_equal 'Bonjour', Prism::I18n.t('hello', locale: :fr)
    end
  end

  def test_best_locale_from_accept_picks_exact_match_by_q_value
    header = 'fr;q=0.5, pl;q=0.9, en;q=0.1'
    assert_equal :pl, Prism::I18n.best_locale_from_accept(header)
  end

  def test_best_locale_from_accept_matches_primary_subtag
    assert_equal :en, Prism::I18n.best_locale_from_accept('en-US,en;q=0.8')
  end

  def test_best_locale_from_accept_returns_nil_when_nothing_available
    assert_nil Prism::I18n.best_locale_from_accept('de,es;q=0.5')
  end

  def test_best_locale_from_accept_returns_nil_for_blank_header
    assert_nil Prism::I18n.best_locale_from_accept('')
    assert_nil Prism::I18n.best_locale_from_accept(nil)
  end

  def test_changing_default_locale_invalidates_cached_translator
    assert_equal 'Hello', Prism::I18n.t('hello', locale: :en)
    Prism::I18n.default_locale = :pl
    assert_equal 'Czesc', Prism::I18n.t('hello')
  end
end
