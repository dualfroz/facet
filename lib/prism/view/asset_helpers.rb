module Prism
  # asset_path/stylesheet_link_tag/javascript_include_tag/image_tag look a
  # logical path up in Prism::Assets.manifest when the app has one loaded
  # (Application#enable_assets, normally after Assets::Compiler#compile! ran)
  # and return the fingerprinted "/assets/..." URL; with no manifest loaded
  # (nothing called enable_assets, e.g. a plain dev boot) they fall back to
  # serving the logical path straight from "/assets/" unfingerprinted, the
  # same escape hatch Propshaft's dev mode uses.
  module AssetHelpers
    def asset_path(logical_path)
      if Prism::Assets.enabled?
        "/assets/#{Prism::Assets.manifest.lookup(logical_path)}"
      else
        "/assets/#{logical_path}"
      end
    end

    def stylesheet_link_tag(logical_path, **attributes)
      tag(:link, { rel: 'stylesheet', href: asset_path(logical_path) }.merge(attributes))
    end

    def javascript_include_tag(logical_path, **attributes)
      content_tag(:script, '', { src: asset_path(logical_path) }.merge(attributes))
    end

    def image_tag(logical_path, **attributes)
      tag(:img, { src: asset_path(logical_path) }.merge(attributes))
    end
  end
end
