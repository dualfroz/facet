module Prism
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

        serve(file)
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

      def serve(file)
        body = File.binread(file)
        type = ContentTypes.fetch(File.extname(file).downcase, 'application/octet-stream')
        [200, { 'Content-Type' => type, 'Content-Length' => body.bytesize.to_s }, [body]]
      end
    end
  end
end
