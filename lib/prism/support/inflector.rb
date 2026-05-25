module Prism
  module Inflector
    module_function

    def underscore(string)
      string.to_s
        .gsub(/::/, '/')
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr('-', '_')
        .downcase
    end

    def camelize(string)
      string.to_s.split(/_|\//).map { |part| part[0]&.upcase.to_s + part[1..].to_s }.join
    end

    def pluralize(word)
      text = word.to_s
      return text if text.empty?
      case text
      when /(?:s|x|z|ch|sh)\z/ then "#{text}es"
      when /([^aeiou])y\z/ then "#{text[0..-2]}ies"
      when /fe?\z/ then text.sub(/fe?\z/, 'ves')
      when /s\z/ then text
      else "#{text}s"
      end
    end

    def singularize(word)
      text = word.to_s
      case text
      when /ies\z/ then "#{text[0..-4]}y"
      when /ves\z/ then "#{text[0..-4]}fe"
      when /(?:s|x|z|ch|sh)es\z/ then text[0..-3]
      when /s\z/ then text[0..-2]
      else text
      end
    end

    def tableize(class_name)
      pluralize(underscore(class_name.to_s.split('::').last))
    end

    def classify(table_name)
      camelize(singularize(table_name.to_s))
    end
  end
end
