module Facet
  module AssetHelpers
    def asset_path(logical_path)
      if Facet::Assets.enabled?
        "/assets/#{Facet::Assets.manifest.lookup(logical_path)}"
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
