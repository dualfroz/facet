module Prism
  module Mime
    class UnknownMimeType < StandardError; end

    TYPES = {
      html: 'text/html',
      json: 'application/json',
      xml: 'application/xml',
      text: 'text/plain',
      csv: 'text/csv',
      js: 'application/javascript'
    }.freeze

    EXTENSIONS = TYPES.invert.freeze

    class << self
      def [](symbol)
        TYPES.fetch(symbol.to_sym) { raise UnknownMimeType, "unknown mime type #{symbol.inspect}" }
      end

      def known?(symbol)
        TYPES.key?(symbol.to_sym)
      end

      def symbol_for_content_type(content_type)
        return nil unless content_type
        base = content_type.split(';').first.to_s.strip
        EXTENSIONS[base]
      end

      # Returns the best-matching format symbol for an HTTP Accept header,
      # honoring q-values and falling back to :html for a bare */*.
      def best_from_accept(accept_header)
        return nil if accept_header.nil? || accept_header.strip.empty?

        parse_accept(accept_header).each do |media_type|
          return :html if media_type == '*/*'
          symbol = EXTENSIONS[media_type]
          return symbol if symbol
        end
        nil
      end

      private

      def parse_accept(header)
        entries = header.split(',').filter_map do |part|
          type, *params = part.strip.split(';').map(&:strip)
          next if type.nil? || type.empty?
          quality = 1.0
          params.each { |p| quality = p.sub('q=', '').to_f if p.start_with?('q=') }
          [type, quality]
        end
        entries.sort_by.with_index { |(_, quality), index| [-quality, index] }.map(&:first)
      end
    end
  end
end
