require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class I18nBackendTest < Minitest::Test
  def setup
    @backend = Prism::I18n::Backend.new
  end

  def test_lookup_returns_nil_for_unknown_key
    assert_nil @backend.lookup(:en, 'missing.key')
  end

  def test_store_and_lookup_nested_key
    @backend.store_translations(:en, 'posts' => { 'title' => 'Title', 'body' => 'Body' })
    assert_equal 'Title', @backend.lookup(:en, 'posts.title')
    assert_equal 'Body', @backend.lookup(:en, :'posts.body')
  end

  def test_store_translations_deep_merges_instead_of_replacing
    @backend.store_translations(:en, 'posts' => { 'title' => 'Title' })
    @backend.store_translations(:en, 'posts' => { 'body' => 'Body' })
    assert_equal 'Title', @backend.lookup(:en, 'posts.title')
    assert_equal 'Body', @backend.lookup(:en, 'posts.body')
  end

  def test_locales_lists_every_stored_locale
    @backend.store_translations(:en, 'hello' => 'Hello')
    @backend.store_translations(:pl, 'hello' => 'Czesc')
    assert_equal [:en, :pl], @backend.locales.sort
  end

  def test_lookup_returns_nil_when_key_path_hits_a_non_hash
    @backend.store_translations(:en, 'hello' => 'Hello')
    assert_nil @backend.lookup(:en, 'hello.nested')
  end

  def test_load_file_reads_json_and_uses_basename_as_locale
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'en.json')
      File.write(path, '{"greeting": "Hi %{name}"}')
      locale = @backend.load_file(path)
      assert_equal :en, locale
      assert_equal 'Hi %{name}', @backend.lookup(:en, 'greeting')
    end
  end

  def test_clear_removes_all_translations
    @backend.store_translations(:en, 'hello' => 'Hello')
    @backend.clear!
    assert_empty @backend.locales
  end
end
