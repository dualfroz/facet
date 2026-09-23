module Facet
  module Middleware
    class Static
      ContentTypes = {
        '.html' => 'text/html;charset=utf-8', '.htm' => 'text/html;charset=utf-8',
        '.css' => 'text/css', '.js' => 'application/javascript', '.json' => 'application/json',
        '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.gif' => 'image/gif',
        '.svg' => 'image/svg+xml', '.ico' => 'image/x-icon', '.txt' => 'text/plain', '.pdf' => 'application/pdf'
      }.freeze

      def initialize(app, root:)
        @app = app
        @root = File.expand_path(root)
      end

      def call(env)
        method = env['REQUEST_METHOD']
        return @app.call(env) unless %w[GET HEAD].include?(method)

        file = resolve(env['PATH_INFO'])
        return @app.call(env) unless file

        serve(file, head: method == 'HEAD', env: env)
      end

      private

      def resolve(path_info)
        return nil if path_info.nil? || path_info.include?("\0")
        decoded = CGI.unescape(path_info)
        candidate = File.expand_path(File.join(@root, decoded))
        return nil unless candidate.start_with?("#{@root}#{File::SEPARATOR}") || candidate == @root
        return File.join(candidate, 'index.html') if File.directory?(candidate) && File.file?(File.join(candidate, 'index.html'))
        return nil unless File.file?(candidate)
        candidate
      end

      def serve(file, head: false, env: {})
        type = ContentTypes.fetch(File.extname(file).downcase, 'application/octet-stream')
        etag, last_modified = StaticCache.weak_validators(File.size(file), File.mtime(file))
        Static.respond_with_range(file, type, head: head, env: env, etag: etag, last_modified: last_modified)
      end

      def self.respond_with_range(file, type, head: false, env: {}, etag: nil, last_modified: nil)
        size = File.size(file)
        headers = { 'Content-Type' => type, 'Accept-Ranges' => 'bytes' }
        headers['ETag'] = etag if etag
        headers['Last-Modified'] = last_modified if last_modified

        if StaticCache.not_modified?(env, etag, last_modified)
          return [304, cache_only_headers(etag, last_modified), []]
        end

        range = env['HTTP_RANGE']
        range = nil unless StaticCache.range_applicable?(env, etag, last_modified)

        parsed = HttpRange.parse(range, size)
        if parsed == :unsatisfiable
          headers['Content-Range'] = "bytes */#{size}"
          return [416, headers, []]
        end

        if parsed.nil?
          headers['Content-Length'] = size.to_s
          body = head ? [] : [File.binread(file)]
          return [200, headers, body]
        end

        headers['Content-Range'] = "bytes #{parsed.start}-#{parsed.finish}/#{size}"
        headers['Content-Length'] = parsed.length.to_s
        body = head ? [] : [HttpRange.read_slice(file, parsed)]
        [206, headers, body]
      end

      def self.cache_only_headers(etag, last_modified)
        headers = {}
        headers['ETag'] = etag if etag
        headers['Last-Modified'] = last_modified if last_modified
        headers
      end
    end
  end
end
