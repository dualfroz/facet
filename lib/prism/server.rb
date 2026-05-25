module Prism
  class Server
    StatusTexts = {
      200 => 'OK', 201 => 'Created', 204 => 'No Content',
      301 => 'Moved Permanently', 302 => 'Found', 303 => 'See Other',
      304 => 'Not Modified', 400 => 'Bad Request', 401 => 'Unauthorized',
      403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
      422 => 'Unprocessable Entity', 500 => 'Internal Server Error'
    }.freeze

    attr_reader :host, :port

    def initialize(app, host: '127.0.0.1', port: 0)
      @app = app
      @host = host
      @requested_port = port
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

    def keep_alive?(env, headers)
      return false if headers['Connection'].to_s.downcase == 'close'
      env['HTTP_CONNECTION'].to_s.downcase != 'close'
    end

    def write_response(socket, status, headers, body, keep_alive)
      payload = body.join
      out = +"HTTP/1.1 #{status} #{status_text(status)}\r\n"
      response_headers = headers.dup
      response_headers['Content-Length'] = payload.bytesize.to_s
      response_headers['Connection'] = keep_alive ? 'keep-alive' : 'close'
      response_headers.each do |name, value|
        value.to_s.split("\n").each { |entry| out << "#{name}: #{entry}\r\n" }
      end
      out << "\r\n"
      socket.write(out)
      socket.write(payload) unless payload.empty?
    end

    def status_text(status)
      StatusTexts.fetch(status, 'OK')
    end
  end
end
