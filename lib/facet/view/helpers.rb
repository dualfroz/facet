require_relative 'tag_builder'
require_relative 'form_builder'
require_relative 'form_helpers'
require_relative 'url_helpers'
require_relative 'content_for_helpers'
require_relative 'cache_helpers'
require_relative 'pagination_helpers'
require_relative 'asset_helpers'

module Facet
  module ViewHelpers
    include TagBuilder
    include FormHelpers
    include UrlHelpers
    include ContentForHelpers
    include CacheHelpers
    include PaginationHelpers
    include AssetHelpers
  end

  module Template
    class Context
      include ViewHelpers
    end
  end
end
