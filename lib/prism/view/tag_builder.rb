module Prism
  # HTML tag construction shared by every other view helper. `tag` and the
  # content-returning form of `content_tag` are meant to be used from a
  # `<%== %>` template tag (they hand back an already-escaped string);
  # the block form of `content_tag` is meant to be used from a plain
  # `<% %>` tag and appends itself to the template's output buffer, same
  # as `form_for` (see Prism::Template::Context#capture).
  module TagBuilder
    def tag(name, attributes = {})
      "<#{name}#{html_attributes(attributes)}>"
    end

    def content_tag(name, content = nil, attributes = {})
      if block_given?
        attributes = content if content.is_a?(Hash)
        inner = capture { yield }
        @__out << "<#{name}#{html_attributes(attributes)}>#{inner}</#{name}>"
        nil
      else
        "<#{name}#{html_attributes(attributes)}>#{escape_html(content.to_s)}</#{name}>"
      end
    end

    def html_attributes(attributes)
      return '' if attributes.nil? || attributes.empty?
      attributes.filter_map { |key, value| html_attribute(key, value) }.join
    end

    private

    def html_attribute(key, value)
      return nil if value.nil? || value == false
      name = key.to_s.tr('_', '-')
      return %( #{name}="#{name}") if value == true
      %( #{name}="#{escape_html(value.to_s)}")
    end
  end
end
