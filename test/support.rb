require 'facet'
require 'stringio'

module TestSupport
  def env_for(method, path, headers: {}, body: nil, cookies: nil)
    path_part, query = path.split('?', 2)
    env = {
      'REQUEST_METHOD' => method.to_s.upcase,
      'PATH_INFO' => path_part,
      'QUERY_STRING' => query.to_s,
      'rack.input' => StringIO.new(body || ''),
      'CONTENT_LENGTH' => (body ? body.bytesize.to_s : '0')
    }
    headers.each do |name, value|
      if name.downcase == 'content-type'
        env['CONTENT_TYPE'] = value
      else
        env["HTTP_#{name.upcase.tr('-', '_')}"] = value
      end
    end
    env['HTTP_COOKIE'] = cookies if cookies
    env
  end
end
