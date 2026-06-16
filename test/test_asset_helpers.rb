require 'minitest/autorun'
require 'prism'

class AssetHelpersTest < Minitest::Test
  def setup
    Prism::Assets.reset!
    @context = Prism::Template::Context.new
  end

  def teardown
    Prism::Assets.reset!
  end

  def test_asset_path_falls_back_to_the_logical_path_without_a_manifest
    assert_equal '/assets/application.css', @context.asset_path('application.css')
  end

  def test_asset_path_uses_the_manifest_when_one_is_loaded
    Prism::Assets.manifest = Prism::Assets::Manifest.new('application.css' => 'application-deadbeef.css')
    assert_equal '/assets/application-deadbeef.css', @context.asset_path('application.css')
  end

  def test_asset_path_raises_for_an_unknown_asset_once_a_manifest_is_loaded
    Prism::Assets.manifest = Prism::Assets::Manifest.new
    assert_raises(Prism::Assets::Manifest::AssetNotFound) { @context.asset_path('missing.css') }
  end

  def test_stylesheet_link_tag
    Prism::Assets.manifest = Prism::Assets::Manifest.new('application.css' => 'application-deadbeef.css')
    assert_equal '<link rel="stylesheet" href="/assets/application-deadbeef.css">',
                 @context.stylesheet_link_tag('application.css')
  end

  def test_javascript_include_tag
    Prism::Assets.manifest = Prism::Assets::Manifest.new('application.js' => 'application-cafef00d.js')
    assert_equal '<script src="/assets/application-cafef00d.js"></script>',
                 @context.javascript_include_tag('application.js')
  end

  def test_image_tag_with_extra_attributes
    assert_equal '<img src="/assets/logo.png" alt="Logo">',
                 @context.image_tag('logo.png', alt: 'Logo')
  end
end
