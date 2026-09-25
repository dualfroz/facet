require 'minitest/autorun'
require 'facet'
require 'support'

class RequestTest < Minitest::Test
  include TestSupport

  def test_query_params
    request = Facet::Request.new(env_for('GET', '/s?q=ruby&page=3'))
    assert_equal 'ruby', request.params['q']
    assert_equal '3', request.params['page']
  end

  def test_json_body
    payload = JSON.generate(name: 'alice', role: 'admin')
    request = Facet::Request.new(env_for('POST', '/u', headers: { 'Content-Type' => 'application/json' }, body: payload))
    assert_equal 'alice', request.params['name']
    assert_equal 'admin', request.params[:role]
  end

  def test_form_body
    request = Facet::Request.new(env_for('POST', '/u', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: 'a=1&b=two'))
    assert_equal '1', request.params['a']
    assert_equal 'two', request.params['b']
  end

  def test_cookies
    request = Facet::Request.new(env_for('GET', '/', cookies: 'foo=bar; baz=qux'))
    assert_equal 'bar', request.cookies['foo']
    assert_equal 'qux', request.cookies['baz']
  end

  def test_headers
    request = Facet::Request.new(env_for('GET', '/', headers: { 'X-Custom' => 'yes' }))
    assert_equal 'yes', request.headers['X-Custom']
  end

  def test_user_agent_and_remote_addr
    env = env_for('GET', '/', headers: { 'User-Agent' => 'TestBrowser/1.0' })
    env['REMOTE_ADDR'] = '203.0.113.7'
    request = Facet::Request.new(env)
    assert_equal 'TestBrowser/1.0', request.user_agent
    assert_equal '203.0.113.7', request.remote_addr
  end

  def test_user_agent_and_remote_addr_absent
    request = Facet::Request.new(env_for('GET', '/'))
    assert_nil request.user_agent
    assert_nil request.remote_addr
  end

  def test_params_precedence
    env = env_for('POST', '/x?id=query',
                  headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                  body: 'id=body')
    request = Facet::Request.new(env)
    request.path_params = { 'id' => 'path' }
    assert_equal 'path', request.params['id']
  end

  def test_method_override_via_body_param
    env = env_for('POST', '/posts/1', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                       body: 'title=hi&_method=patch')
    request = Facet::Request.new(env)
    assert_equal 'PATCH', request.request_method
  end

  def test_method_override_via_header
    env = env_for('POST', '/posts/1', headers: { 'X-Http-Method-Override' => 'delete' })
    request = Facet::Request.new(env)
    assert_equal 'DELETE', request.request_method
  end

  def test_method_override_ignores_unknown_verb
    env = env_for('POST', '/posts', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                     body: '_method=trace')
    request = Facet::Request.new(env)
    assert_equal 'POST', request.request_method
  end

  def test_method_override_does_not_starve_body_for_a_second_reader
    env = env_for('POST', '/posts', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                     body: 'title=hello&_method=put')
    first = Facet::Request.new(env)
    assert_equal 'PUT', first.request_method
    second = Facet::Request.new(env)
    assert_equal 'hello', second.params['title']
  end

  def test_multipart_body_mixes_fields_and_files
    boundary = '----FacetReqBoundary42'
    body = "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"title\"\r\n\r\nmy post\r\n" \
           "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"avatar\"; filename=\"pic.png\"\r\n" \
           "Content-Type: image/png\r\n\r\nbinarydata\r\n" \
           "--#{boundary}--\r\n"
    env = env_for('POST', '/uploads',
                  headers: { 'Content-Type' => "multipart/form-data; boundary=#{boundary}" },
                  body: body)
    request = Facet::Request.new(env)
    assert_equal 'my post', request.params['title']

    file = request.params['avatar']
    assert_instance_of Facet::UploadedFile, file
    assert_equal 'pic.png', file.original_filename
    assert_equal 'image/png', file.content_type
    assert_equal 'binarydata', file.read
  end

  def test_multipart_without_boundary_yields_empty_params
    env = env_for('POST', '/uploads', headers: { 'Content-Type' => 'multipart/form-data' }, body: 'ignored')
    request = Facet::Request.new(env)
    assert_empty request.params
  end
end
