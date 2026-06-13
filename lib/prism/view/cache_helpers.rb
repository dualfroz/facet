module Prism
  # `cache(key) { ... }` used from a plain `<% %>` template tag: renders the
  # block once, stores the resulting markup in Prism::Cache.store keyed by
  # Prism::View#expand_cache_key(key), and on a hit appends the stored
  # markup straight to the buffer without re-evaluating the block at all.
  # `key` may be a String/Symbol, a model instance (uses #cache_key) or an
  # Array mixing both (e.g. `cache [:sidebar, current_user, post]`).
  module CacheHelpers
    def cache(key, expires_in: nil)
      raise 'no view attached to this template' unless @view
      cache_key = @view.expand_cache_key(key)
      cached = Prism::Cache.store.read(cache_key)
      if cached
        @__out << cached
      else
        fragment = capture { yield }
        Prism::Cache.store.write(cache_key, fragment, expires_in: expires_in)
        @__out << fragment
      end
      nil
    end
  end
end
