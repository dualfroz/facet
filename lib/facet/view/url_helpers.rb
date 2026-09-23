module Facet
  module UrlHelpers
    def link_to(text, url, attributes = {})
      content_tag(:a, text, attributes.merge(href: url))
    end

    def button_to(text, url, method: :post, form: {}, **button_attrs)
      verb = method.to_s.upcase
      markup = +"<form action=\"#{escape_html(url)}\" method=\"post\"#{html_attributes(form.merge(class: [form[:class], 'button-to'].compact.join(' ')))}>"
      markup << hidden_method_field(verb) unless verb == 'POST'
      markup << csrf_hidden_field
      markup << content_tag(:button, text, { type: 'submit' }.merge(button_attrs))
      markup << '</form>'
      markup
    end
  end
end
