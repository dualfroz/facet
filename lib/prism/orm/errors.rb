module Prism
  module Orm
    class Errors
      include Enumerable

      def initialize
        @messages = Hash.new { |hash, key| hash[key] = [] }
      end

      def add(attribute, message)
        @messages[attribute.to_sym] << message
      end

      def [](attribute)
        @messages[attribute.to_sym]
      end

      def key?(attribute)
        @messages.key?(attribute.to_sym)
      end

      def clear
        @messages.clear
      end

      def empty?
        @messages.empty?
      end

      def any?
        !empty?
      end

      def each(&block)
        @messages.each(&block)
      end

      def full_messages
        @messages.flat_map { |attribute, messages| messages.map { |message| "#{attribute} #{message}" } }
      end

      # JSON:API error object array (https://jsonapi.org/format/#error-objects):
      # one entry per failed validation, `source.pointer` naming the exact
      # attribute so a client can highlight the right form field without
      # parsing `detail` text. `title` is the raw message (stable across
      # occurrences, e.g. "can't be blank"); `detail` reuses the exact
      # `"#{attribute} #{message}"` wording `full_messages` produces, so the
      # two representations never drift apart.
      def to_jsonapi(status: 422)
        status_string = status.to_s
        @messages.flat_map do |attribute, messages|
          messages.map do |message|
            {
              status: status_string,
              source: { pointer: "/data/attributes/#{attribute}" },
              title: message,
              detail: "#{attribute} #{message}"
            }
          end
        end
      end
    end
  end
end
