module Prism
  class Server
    StatusTexts = {
      200 => 'OK', 201 => 'Created', 204 => 'No Content',
      301 => 'Moved Permanently', 302 => 'Found', 303 => 'See Other',
      304 => 'Not Modified', 400 => 'Bad Request', 401 => 'Unauthorized',
      403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
      422 => 'Unprocessable Entity', 500 => 'Internal Server Error'
    }.freeze

    attr_reader :host, :port, :websocket_connection_count

    # `max_websocket_connections:` is a hard cap on the number of LIVE
    # WebSocket connections held by this process, across every registered
    # endpoint and every stream - distinct from
    # WebSocket::Hub#max_subscribers_per_stream, which only limits how many
    # connections may subscribe to one particular broadcast stream. Without
    # this, a process serving N different posts each under their own
    # per-stream cap could still be driven to opening unbounded sockets by
    # spreading connections across many streams. `nil` (default) preserves
    # the old unbounded behavior.
    def initialize(app, host: '127.0.0.1', port: 0, max_websocket_connections: nil)
      @app = app
      @host = host
      @requested_port = port
      @max_websocket_connections = max_websocket_connections
      @websocket_connection_count = 0
      @websocket_connection_mutex = Mutex.new
    end

    def start
      @server = TCPServer.new(@host, @requested_port)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
      self
    end

    def stop
      @server&.close
      @thread&.join(1)
      self
    end

    def url(path = '/')
      "http://#{@host}:#{@port}#{path}"
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(socket)
      loop do
        env = read_request(socket)
        break unless env
        if WebSocket::Handshake.request?(env) && (handler = websocket_handler_for(env))
          handle_websocket(socket, env, handler)
          break
        end
        status, headers, body = @app.call(env)
        keep_alive = keep_alive?(env, headers)
        write_response(socket, status, headers, body, keep_alive)
        break unless keep_alive
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      socket.close unless socket.closed?
    end

    # Looked up on `@app` directly (not through the middleware/Rack `call`
    # chain) because an Upgrade: websocket request never gets a normal HTTP
    # response - it either becomes a 101 handshake handed off to
    # WebSocket::Connection, or it falls through to the ordinary Rack app
    # (and 404s there) when no handler is registered for the path.
    def websocket_handler_for(env)
      return nil unless @app.respond_to?(:find_websocket_handler)
      @app.find_websocket_handler(env['PATH_INFO'])
    end

    # Compacted so an unset `max_message_size:` (nil, the common case) is
    # never passed through to Connection.new at all - passing it explicitly
    # as nil would override Connection's own DEFAULT_MAX_MESSAGE_SIZE
    # keyword default with nil instead of leaving it alone.
    def connection_options(env)
      return {} unless @app.respond_to?(:find_websocket_options)
      @app.find_websocket_options(env['PATH_INFO']).compact
    end

    def handle_websocket(socket, env, handler_class)
      unless acquire_websocket_slot
        write_response(socket, 503, { 'Content-Type' => 'text/plain' }, ['too many websocket connections'], false)
        return
      end

      begin
        socket.write("HTTP/1.1 101 Switching Protocols\r\n")
        WebSocket::Handshake.response_headers(env).each { |name, value| socket.write("#{name}: #{value}\r\n") }
        socket.write("\r\n")

        connection = WebSocket::Connection.new(socket, env: env, **connection_options(env))
        handler = handler_class.new
        handler.on_open(connection) if handler.respond_to?(:on_open)
        begin
          while (message = connection.read_message)
            handler.on_message(connection, message) if handler.respond_to?(:on_message)
          end
        rescue WebSocket::ProtocolError
          nil
        ensure
          handler.on_close(connection) if handler.respond_to?(:on_close)
        end
      ensure
        release_websocket_slot
      end
    end

    # Checked and incremented under the same mutex so two connections
    # racing to grab the last slot cannot both succeed - the check and the
    # reservation are one atomic step, not two.
    def acquire_websocket_slot
      return true unless @max_websocket_connections

      @websocket_connection_mutex.synchronize do
        return false if @websocket_connection_count >= @max_websocket_connections
        @websocket_connection_count += 1
        true
      end
    end

    def release_websocket_slot
      return unless @max_websocket_connections

      @websocket_connection_mutex.synchronize { @websocket_connection_count -= 1 }
    end

    def read_request(socket)
      request_line = socket.gets("\r\n")
      return nil if request_line.nil?
      request_line = request_line.strip
      return nil if request_line.empty?

      method, target, = request_line.split(' ', 3)
      path, query = target.split('?', 2)

      headers = {}
      while (line = socket.gets("\r\n"))
        line = line.chomp("\r\n")
        break if line.empty?
        name, value = line.split(':', 2)
        headers[name.strip.downcase] = value.to_s.strip
      end

      env = {
        'REQUEST_METHOD' => method,
        'PATH_INFO' => path,
        'QUERY_STRING' => query.to_s,
        'SERVER_NAME' => @host,
        'SERVER_PORT' => @port.to_s,
        'REMOTE_ADDR' => remote_addr(socket),
        'rack.url_scheme' => 'http'
      }
      headers.each do |name, value|
        env["HTTP_#{name.upcase.tr('-', '_')}"] = value
      end
      env['CONTENT_TYPE'] = headers['content-type'] if headers['content-type']
      length = headers['content-length'].to_i
      env['CONTENT_LENGTH'] = length.to_s
      env['rack.input'] = StringIO.new(length.positive? ? socket.read(length) : '')
      env
    end

    # The client's numeric IP, the standard Rack env key that
    # Middleware::RateLimiting (and anything else keying off the caller's
    # address) relies on - `peeraddr(false)` skips the reverse DNS lookup,
    # since only the numeric address (index 3) is ever used.
    def remote_addr(socket)
      socket.peeraddr(false)[3]
    rescue IOError, Errno::ENOTCONN, SocketError
      nil
    end

    def keep_alive?(env, headers)
      return false if headers['Connection'].to_s.downcase == 'close'
      env['HTTP_CONNECTION'].to_s.downcase != 'close'
    end

    def write_response(socket, status, headers, body, keep_alive)
      if body.is_a?(StreamingBody)
        write_chunked_response(socket, status, headers, body, keep_alive)
      else
        write_buffered_response(socket, status, headers, body, keep_alive)
      end
    end

    def write_buffered_response(socket, status, headers, body, keep_alive)
      payload = body.join
      response_headers = headers.dup
      response_headers['Content-Length'] = payload.bytesize.to_s
      socket.write(status_line_and_headers(status, response_headers, keep_alive))
      socket.write(payload) unless payload.empty?
    end

    # The body's total size is unknowable up front - that is the entire
    # reason to stream instead of building one payload String first - so
    # this sends `Transfer-Encoding: chunked` (RFC 7230 SS4.1) instead of a
    # `Content-Length`, and writes each chunk `body#each` produces as its
    # own `<hex size>\r\n<data>\r\n` frame the moment it is produced,
    # followed by the zero-length terminating chunk once the producer block
    # returns. A `write` call happening as fast, or as slowly, as the
    # action generates data is the entire point - nothing here buffers
    # more than one chunk at a time.
    def write_chunked_response(socket, status, headers, body, keep_alive)
      response_headers = headers.dup
      response_headers.delete('Content-Length')
      response_headers['Transfer-Encoding'] = 'chunked'
      socket.write(status_line_and_headers(status, response_headers, keep_alive))
      body.each do |chunk|
        next if chunk.empty?
        socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
      end
      socket.write("0\r\n\r\n")
    end

    def status_line_and_headers(status, response_headers, keep_alive)
      out = +"HTTP/1.1 #{status} #{status_text(status)}\r\n"
      response_headers['Connection'] = keep_alive ? 'keep-alive' : 'close'
      response_headers.each do |name, value|
        value.to_s.split("\n").each { |entry| out << "#{name}: #{entry}\r\n" }
      end
      out << "\r\n"
      out
    end

    def status_text(status)
      StatusTexts.fetch(status, 'OK')
    end
  end
end
