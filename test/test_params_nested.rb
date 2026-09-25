require 'minitest/autorun'
require 'facet'
require 'support'

class ParamsNestedTest < Minitest::Test
  include TestSupport

  def test_nested_from_expands_bracketed_keys_into_a_hash
    params = Facet::Params.nested_from([['post[title]', 'hi'], ['post[body]', 'yo']])
    assert_equal 'hi', params['post']['title']
    assert_equal 'yo', params['post']['body']
  end

  def test_nested_from_collects_trailing_brackets_into_an_array
    params = Facet::Params.nested_from([['tags[]', 'ruby'], ['tags[]', 'web']])
    assert_equal %w[ruby web], params['tags']
  end

  def test_nested_from_supports_an_array_nested_under_a_hash_key
    params = Facet::Params.nested_from([['post[tags][]', 'a'], ['post[tags][]', 'b']])
    assert_equal %w[a b], params['post']['tags']
  end

  def test_nested_from_supports_multiple_levels_of_nesting
    params = Facet::Params.nested_from([['address[city][zip]', '00-001']])
    assert_equal '00-001', params['address']['city']['zip']
  end

  def test_nested_from_leaves_plain_keys_untouched
    params = Facet::Params.nested_from([['title', 'hi']])
    assert_equal 'hi', params['title']
  end

  def test_nested_from_symbol_and_string_keys_are_interchangeable_at_every_level
    params = Facet::Params.nested_from([['post[title]', 'hi']])
    assert_equal 'hi', params[:post][:title]
  end

  def test_urlencoded_form_body_with_object_bracket_names_is_parsed_as_nested_params
    request = Facet::Request.new(env_for('POST', '/posts',
                                          headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                          body: 'post%5Btitle%5D=Hello&post%5Bbody%5D=World&tags%5B%5D=a&tags%5B%5D=b'))
    assert_equal 'Hello', request.params['post']['title']
    assert_equal 'World', request.params['post']['body']
    assert_equal %w[a b], request.params['tags']
  end

  def test_urlencoded_query_string_with_object_bracket_names_is_parsed_as_nested_params
    request = Facet::Request.new(env_for('GET', '/search?filter%5Bname%5D=fox&filter%5Bactive%5D=1'))
    assert_equal 'fox', request.params['filter']['name']
    assert_equal '1', request.params['filter']['active']
  end

  def test_nested_form_params_survive_a_strong_parameters_require_and_permit_round_trip
    request = Facet::Request.new(env_for('POST', '/posts',
                                          headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                          body: 'post%5Btitle%5D=Hello&post%5Badmin%5D=1'))
    permitted = request.params.require(:post).permit(:title)
    assert_equal({ 'title' => 'Hello' }, permitted.to_h)
  end

  def test_multipart_body_with_object_bracket_names_is_parsed_as_nested_params
    boundary = '----ParamsNestedTestBoundary'
    body = [
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"post[title]\"\r\n\r\nHello\r\n",
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"post[cover]\"; filename=\"a.png\"\r\n" \
        "Content-Type: image/png\r\n\r\nbytes\r\n",
      "--#{boundary}--\r\n"
    ].join
    request = Facet::Request.new(env_for('POST', '/posts',
                                          headers: { 'Content-Type' => "multipart/form-data; boundary=#{boundary}" },
                                          body: body))
    assert_equal 'Hello', request.params['post']['title']
    assert_instance_of Facet::UploadedFile, request.params['post']['cover']
    assert_equal 'a.png', request.params['post']['cover'].original_filename
  end
end
