module Prism
  # Binds a set of <input>/<select>/<textarea> tags to a model instance:
  # field names/ids follow Rails' `object[attribute]` convention so params
  # arrive nested and ready for StrongParameters (`params.require(:post).permit(...)`),
  # and values/errors are read straight off the bound object.
  class FormBuilder
    include TagBuilder

    attr_reader :object, :object_name

    def initialize(object, object_name: nil)
      @object = object
      @object_name = (object_name || infer_object_name(object)).to_s
    end

    def label(attribute, text = nil, **attrs)
      content_tag(:label, text || humanize(attribute), attrs.merge(for: field_id(attribute)))
    end

    def hidden_field(attribute, **attrs)
      input_tag(attribute, 'hidden', attrs)
    end

    def text_field(attribute, **attrs)
      input_tag(attribute, 'text', attrs)
    end

    def password_field(attribute, **attrs)
      options = attrs.dup
      options[:value] = options.fetch(:value, '')
      input_tag(attribute, 'password', options)
    end

    def email_field(attribute, **attrs)
      input_tag(attribute, 'email', attrs)
    end

    def number_field(attribute, **attrs)
      input_tag(attribute, 'number', attrs)
    end

    def date_field(attribute, **attrs)
      input_tag(attribute, 'date', attrs)
    end

    def text_area(attribute, **attrs)
      options = attrs.dup
      value = options.key?(:value) ? options.delete(:value) : field_value(attribute)
      "<textarea#{html_attributes({ name: field_name(attribute), id: field_id(attribute) }.merge(options))}>#{escape_html(value.to_s)}</textarea>"
    end

    def check_box(attribute, checked_value: '1', unchecked_value: '0', **attrs)
      options = attrs.dup
      checked = options.key?(:checked) ? options.delete(:checked) : truthy?(field_value(attribute))
      hidden = tag(:input, type: 'hidden', name: field_name(attribute), value: unchecked_value)
      box = tag(:input, { type: 'checkbox', name: field_name(attribute), id: field_id(attribute),
                           value: checked_value, checked: checked }.merge(options))
      hidden + box
    end

    def select(attribute, choices, include_blank: false, **attrs)
      current = field_value(attribute)
      body = +''
      body << option_tag('', '', current.nil? || current == '') if include_blank
      choices.each do |choice|
        text, value = choice.is_a?(Array) ? choice : [choice, choice]
        body << option_tag(text, value, value.to_s == current.to_s)
      end
      "<select#{html_attributes({ name: field_name(attribute), id: field_id(attribute) }.merge(attrs))}>#{body}</select>"
    end

    def submit(value = 'Save', **attrs)
      tag(:input, { type: 'submit', value: value }.merge(attrs))
    end

    # Nested-attributes counterpart to a plain field: yields a fresh
    # FormBuilder per record in `collection` (defaults to
    # `object.public_send(association)`), each named
    # "post[comments_attributes][0]" so submitted fields land at
    # "post[comments_attributes][0][body]" - exactly the bracket shape
    # Prism::Params.nested_from expands back into an indexed Hash, which is
    # what StrongParameters#permit and Model#accepts_nested_attributes_for
    # both expect on the way back in. Every yielded builder is over an
    # ALREADY-PERSISTED record (`f.hidden_field(:id)` inside the block is
    # what makes update-vs-destroy resolution possible server-side) -
    # building brand-new nested rows in a form is a separate, JS-assisted
    # concern this helper does not attempt.
    def fields_for(association, collection = nil)
      records = collection || @object.public_send(association)
      Array(records).each_with_index do |record, index|
        yield FormBuilder.new(record, object_name: "#{@object_name}[#{association}_attributes][#{index}]")
      end
      nil
    end

    def errors_for(attribute)
      return [] unless @object.respond_to?(:errors)
      @object.errors[attribute]
    end

    def error_messages(attribute, wrapper: :span, **attrs)
      messages = errors_for(attribute)
      return '' if messages.empty?
      content_tag(wrapper, messages.join(', '), { class: 'field-error' }.merge(attrs))
    end

    private

    def escape_html(text)
      CGI.escapeHTML(text)
    end

    def input_tag(attribute, type, attrs)
      options = attrs.dup
      value = options.key?(:value) ? options.delete(:value) : field_value(attribute)
      tag(:input, { type: type, name: field_name(attribute), id: field_id(attribute), value: value }.merge(options))
    end

    def option_tag(text, value, selected)
      "<option#{html_attributes(value: value, selected: selected)}>#{escape_html(text.to_s)}</option>"
    end

    def field_name(attribute)
      "#{@object_name}[#{attribute}]"
    end

    # For a plain object_name ("post") this is a no-op; for a fields_for
    # nested builder ("post[comments_attributes][0]") it turns the bracket
    # notation used in `name=` into a flat, HTML-id-legal token
    # ("post_comments_attributes_0") the same way Rails does.
    def field_id(attribute)
      "#{@object_name.tr('[]', '_').squeeze('_').sub(/_\z/, '')}_#{attribute}"
    end

    def field_value(attribute)
      @object.respond_to?(attribute) ? @object.public_send(attribute) : nil
    end

    def humanize(attribute)
      attribute.to_s.tr('_', ' ').capitalize
    end

    def truthy?(value)
      !(value.nil? || value == false || value == '' || value == 0 || value == '0')
    end

    def infer_object_name(object)
      klass = object.is_a?(Class) ? object : object.class
      Inflector.underscore(klass.name.to_s.split('::').last)
    end
  end
end
