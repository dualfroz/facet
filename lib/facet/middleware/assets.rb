module Facet
  module Middleware
    class Assets
      FINGERPRINTED = /-([0-9a-f]{8})\.[^.]+\z/.freeze

      def initialize(app, root:, prefix: '/assets')
        @app = app
        @root = File.expand_path(root)
        @prefix = prefix.chomp('/')
      end

      def call(env)
        method = env['REQUEST_METHOD']
        path_info = env['PATH_INFO']
        return @app.call(env) unless %w[GET HEAD].include?(method)
        return @app.call(env) unless path_info&.start_with?("#{@prefix}/")

        file = resolve(path_info.delete_prefix(@prefix))
        return @app.call(env) unless file

        serve(file, head: method == 'HEAD', env: env)
      end

      private

      def resolve(relative)
        return nil if relative.include?("\0")

        candidate = File.expand_path(File.join(@root, CGI.unescape(relative)))
        return nil unless candidate.start_with?("#{@root}#{File::SEPARATOR}")
        return nil unless File.file?(candidate)

        candidate
      end

      def serve(file, head: false, env: {})
        type = Static::ContentTypes.fetch(File.extname(file).downcase, 'application/octet-stream')
        fingerprint = FINGERPRINTED.match(File.basename(file))

        etag, last_modified =
          if fingerprint
            [StaticCache.strong_etag(fingerprint[1]), File.mtime(file).utc.httpdate]
          else
            StaticCache.weak_validators(File.size(file), File.mtime(file))
          end

        status, headers, body = Static.respond_with_range(file, type, head: head, env: env, etag: etag, last_modified: last_modified)
        headers['Cache-Control'] = 'public, max-age=31536000, immutable' if fingerprint
        [status, headers, body]
      end
    end
  end
end
