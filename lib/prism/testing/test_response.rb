module Prism
  module Testing
    # Wraps the [status, headers, body] triple a Rack-style app returns so
    # integration tests can assert on it without touching the raw array.
    class TestResponse
      attr_reader :status, :headers, :body

      def initialize(status, headers, body_parts)
        @status = status
        @headers = headers
        # #each (not Array(body_parts)) so a StreamingBody (see
        # Prism::StreamingBody) is drained into one String just like an
        # ordinary body Array would be - an integration test asserting on
        # `response.body` needs the whole thing collected either way, it
        # just never gets streamed to a real socket one chunk at a time.
        parts = []
        body_parts.each { |chunk| parts << chunk }
        @body = parts.join
      end

      def content_type
        headers['Content-Type']
      end

      def location
        headers['Location']
      end

      def success?
        (200..299).cover?(status)
      end

      def redirect?
        (300..399).cover?(status)
      end

      def not_found?
        status == 404
      end

      def client_error?
        (400..499).cover?(status)
      end

      def server_error?
        (500..599).cover?(status)
      end

      # name => raw (still cookie-encoded) value, one entry per Set-Cookie
      # line. Multiple Set-Cookie headers are joined with "\n" by
      # Prism::Response#set_cookie, matching the old Rack convention this
      # codebase follows.
      def set_cookies
        raw = headers['Set-Cookie']
        return {} unless raw

        raw.split("\n").each_with_object({}) do |line, acc|
          name, value = line.split(';', 2).first.to_s.split('=', 2)
          acc[name] = value.to_s if name
        end
      end

      def json
        JSON.parse(body)
      end
    end
  end
end
