require 'cgi'

module Prism
  module Helpers
    class SafeString < String
      def html_safe?
        true
      end

      def html_safe
        self
      end

      def to_s
        self
      end

      def to_str
        String.new(self)
      end

      def <<(other)
        super(coerce(other))
      end
      alias_method :concat, :<<

      def +(other)
        dup.concat(other)
      end

      def *(times)
        self.class.new(String.instance_method(:*).bind_call(self, times))
      end

      private

      def coerce(other)
        other.is_a?(SafeString) ? other.to_str : CGI.escapeHTML(other.to_s)
      end
    end

    class SafeBuffer < SafeString
      def append(other)
        self << other
        self
      end
    end

    module OutputSafety
      ENCODING_MAP = {
        '&' => '&amp;',
        '>' => '&gt;',
        '<' => '&lt;',
        '"' => '&quot;',
        "'" => '&#39;'
      }.freeze

      module_function

      def html_safe(value)
        value.is_a?(SafeString) ? value : SafeString.new(value.to_s)
      end

      def html_escape(value)
        return value if value.is_a?(SafeString)
        SafeString.new(CGI.escapeHTML(value.to_s))
      end

      def escape_once(value)
        return value if value.is_a?(SafeString)
        escaped = value.to_s.gsub(/["><']|&(?!([a-zA-Z]+|(#\d+)|(#x[0-9a-fA-F]+));)/, ENCODING_MAP)
        SafeString.new(escaped)
      end

      def safe?(value)
        value.is_a?(SafeString)
      end

      def safe_join(parts, separator = '')
        safe_separator = html_escape(separator).to_str
        joined = Array(parts).flatten.map { |part| html_escape(part).to_str }.join(safe_separator)
        SafeString.new(joined)
      end
    end
  end
end

class String
  unless method_defined?(:html_safe?)
    def html_safe?
      false
    end
  end

  unless method_defined?(:html_safe)
    def html_safe
      Prism::Helpers::SafeString.new(self)
    end
  end
end
