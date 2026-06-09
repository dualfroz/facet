require 'zlib'
require 'stringio'

module Prism
  module Middleware
    # Rack::Deflater-lite: gzips response bodies for clients that send
    # `Accept-Encoding: gzip`, using stdlib Zlib only.
    #
    # A buffered (Array) body is compressed whole, in one shot, and gets an
    # exact Content-Length like any other buffered response. A
    # Prism::StreamingBody (see Response#stream) is re-wrapped in a new
    # StreamingBody that runs a *single* Zlib::Deflate stream across the
    # producer's chunks with Zlib::SYNC_FLUSH after each one - the gzip
    # equivalent of chunked transfer-encoding: the client starts receiving
    # (and can start inflating) compressed bytes as the action produces
    # them, instead of this middleware defeating streaming by buffering the
    # whole response just to gzip it in one go.
    class Compression
      # Recompressing these wastes CPU for no size win (already-compressed
      # media formats), and gzipping a response that already carries a
      # Content-Encoding (someone upstream picked one already) would
      # corrupt it rather than stack with it.
      SKIP_CONTENT_TYPES = %r{\A(?:image|audio|video)/|\Aapplication/(?:gzip|zip|x-gzip|octet-stream)}.freeze
      NO_BODY_STATUSES = [204, 205, 206, 304].freeze

      def initialize(app, threshold: 256)
        @app = app
        @threshold = threshold
      end

      def call(env)
        status, headers, body = @app.call(env)
        return [status, headers, body] unless candidate?(env, status, headers)

        if body.is_a?(StreamingBody)
          [status, gzip_headers(headers), wrap_streaming(body)]
        else
          gzip_buffered(status, headers, body)
        end
      end

      private

      def candidate?(env, status, headers)
        return false if env['REQUEST_METHOD'] == 'HEAD'
        return false unless accepts_gzip?(env['HTTP_ACCEPT_ENCODING'])
        return false if NO_BODY_STATUSES.include?(status)
        return false if headers['Content-Encoding']
        return false if headers['Content-Range']
        return false if headers['Content-Type'].to_s =~ SKIP_CONTENT_TYPES
        true
      end

      # Accept-Encoding: gzip;q=0.8, deflate, br;q=0
      # A coding is acceptable if named with q > 0, or covered by a `*`
      # with q > 0 and not itself named with q=0 (RFC 7231 SS5.3.4).
      def accepts_gzip?(header)
        return false if header.to_s.empty?
        codings = header.split(',').map do |part|
          name, *params = part.strip.split(';').map(&:strip)
          q = params.find { |p| p.start_with?('q=') }
          [name.downcase, q ? q.sub('q=', '').to_f : 1.0]
        end
        gzip = codings.find { |name, _| name == 'gzip' }
        return gzip[1] > 0 if gzip
        wildcard = codings.find { |name, _| name == '*' }
        wildcard ? wildcard[1] > 0 : false
      end

      def gzip_buffered(status, headers, body)
        payload = body.join
        return [status, headers, body] if payload.bytesize < @threshold

        compressed = Zlib.gzip(payload)
        response_headers = gzip_headers(headers)
        response_headers['Content-Length'] = compressed.bytesize.to_s
        [status, response_headers, [compressed]]
      end

      def gzip_headers(headers)
        headers = headers.dup
        headers.delete('Content-Length')
        headers['Content-Encoding'] = 'gzip'
        existing_vary = headers['Vary']
        headers['Vary'] = existing_vary.to_s.empty? ? 'Accept-Encoding' : "#{existing_vary}, Accept-Encoding"
        headers
      end

      def wrap_streaming(body)
        StreamingBody.new do |writer|
          deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16)
          body.each do |chunk|
            next if chunk.empty?
            writer.write(deflater.deflate(chunk, Zlib::SYNC_FLUSH))
          end
          writer.write(deflater.finish)
          deflater.close
        end
      end
    end
  end
end
