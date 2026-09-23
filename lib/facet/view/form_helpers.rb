module Facet
  module FormHelpers
    MethodOverrideVerbs = %w[PUT PATCH DELETE].freeze

    def form_for(record, url:, method: nil, object_name: nil, html: {})
      verb = (method || infer_form_method(record)).to_s.upcase
      builder = FormBuilder.new(record, object_name: object_name)
      @__out << form_open_tag(url, verb, html)
      yield builder
      @__out << '</form>'
      nil
    end
    alias_method :form_with, :form_for

    private

    def infer_form_method(record)
      record.respond_to?(:persisted?) && record.persisted? ? :patch : :post
    end

    def form_open_tag(url, verb, html)
      submit_verb = MethodOverrideVerbs.include?(verb) ? 'post' : verb.downcase
      markup = +"<form action=\"#{escape_html(url)}\" method=\"#{submit_verb}\"#{html_attributes(html)}>"
      markup << hidden_method_field(verb) if MethodOverrideVerbs.include?(verb)
      markup << csrf_hidden_field unless verb == 'GET'
      markup
    end

    def hidden_method_field(verb)
      %(<input type="hidden" name="_method" value="#{verb}">)
    end

    def csrf_hidden_field
      return '' unless respond_to?(:csrf_token)
      token = csrf_token
      return '' unless token
      %(<input type="hidden" name="authenticity_token" value="#{escape_html(token)}">)
    end
  end
end
