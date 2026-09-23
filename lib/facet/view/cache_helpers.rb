module Facet
  module CacheHelpers
    def cache(key, expires_in: nil)
      raise 'no view attached to this template' unless @view
      cache_key = @view.expand_cache_key(key)
      cached = Facet::Cache.store.read(cache_key)
      if cached
        @__out << cached
      else
        fragment = capture { yield }
        Facet::Cache.store.write(cache_key, fragment, expires_in: expires_in)
        @__out << fragment
      end
      nil
    end
  end
end
