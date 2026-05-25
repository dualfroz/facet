module Prism
  module Middleware
    class Logger
      def initialize(app, io: $stderr)
        @app = app
        @io = io
      end

      def call(env)
        started = Time.now
        status, headers, body = @app.call(env)
        elapsed = ((Time.now - started) * 1000).round(2)
        @io.puts(format('%s %s -> %d (%.2f ms)', env['REQUEST_METHOD'], env['PATH_INFO'], status, elapsed))
        [status, headers, body]
      end
    end
  end
end
