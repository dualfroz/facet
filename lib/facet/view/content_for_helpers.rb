module Facet
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
