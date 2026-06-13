module Prism
  # `content_for(:name) { ... }` stashes a captured fragment on the current
  # Prism::View instance instead of the page buffer; `content_for(:name)`
  # (no block) reads it back. This is what lets a content template push
  # markup (a page title, a sidebar widget) into a *different* slot of the
  # layout that renders around it, since the content template and the
  # layout template each get their own Template::Context but share the
  # same View (see Prism::View#render / #content_for_store).
  module ContentForHelpers
    def content_for(name, &block)
      raise 'no view attached to this template' unless @view
      if block
        @view.append_content_for(name, capture(&block))
        nil
      else
        @view.content_for(name)
      end
    end

    def content_for?(name)
      raise 'no view attached to this template' unless @view
      @view.content_for?(name)
    end
  end
end
