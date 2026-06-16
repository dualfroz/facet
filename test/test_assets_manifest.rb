require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class AssetsManifestTest < Minitest::Test
  def test_lookup_returns_the_fingerprinted_path
    manifest = Prism::Assets::Manifest.new('application.css' => 'application-deadbeef.css')
    assert_equal 'application-deadbeef.css', manifest.lookup('application.css')
  end

  def test_lookup_accepts_symbol_or_string
    manifest = Prism::Assets::Manifest.new('application.css' => 'application-deadbeef.css')
    assert_equal 'application-deadbeef.css', manifest.lookup(:'application.css')
  end

  def test_lookup_raises_on_unknown_asset
    manifest = Prism::Assets::Manifest.new
    error = assert_raises(Prism::Assets::Manifest::AssetNotFound) { manifest.lookup('missing.css') }
    assert_match(/missing\.css/, error.message)
  end

  def test_key_predicate
    manifest = Prism::Assets::Manifest.new('a.js' => 'a-11111111.js')
    assert manifest.key?('a.js')
    refute manifest.key?('b.js')
  end

  def test_save_and_load_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'manifest.json')
      original = Prism::Assets::Manifest.new('a.css' => 'a-cafef00d.css', 'b.js' => 'b-0ff1ce00.js')
      original.save(path)

      loaded = Prism::Assets::Manifest.load(path)
      assert_equal original.to_h, loaded.to_h
    end
  end

  def test_load_of_missing_file_returns_an_empty_manifest
    manifest = Prism::Assets::Manifest.load('/no/such/manifest.json')
    refute manifest.key?('anything.css')
  end
end
