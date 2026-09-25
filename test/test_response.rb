require 'minitest/autorun'
require 'facet'

class ResponseTest < Minitest::Test
  def test_defaults
    status, headers, body = Facet::Response.new.finish
    assert_equal 200, status
    assert_equal 'text/html;charset=utf-8', headers['Content-Type']
    assert_equal [], body
  end

  def test_write
    response = Facet::Response.new
    response << 'a'
    response.write('b')
    assert_equal %w[a b], response.finish[2]
  end

  def test_set_cookie
    response = Facet::Response.new
    response.set_cookie('token', 'abc def')
    assert_includes response.headers['Set-Cookie'], 'token=abc+def'
    assert_includes response.headers['Set-Cookie'], 'HttpOnly'
  end

  def test_multiple_cookies
    response = Facet::Response.new
    response.set_cookie('a', '1')
    response.set_cookie('b', '2')
    assert_equal 2, response.headers['Set-Cookie'].split("\n").size
  end

  def test_stream_marks_the_response_as_streaming
    response = Facet::Response.new
    refute response.streaming?
    response.stream { |out| out.write('x') }
    assert response.streaming?
  end

  def test_stream_body_is_a_streaming_body_not_wrapped_in_an_array
    response = Facet::Response.new
    response.stream { |out| out.write('x') }
    _status, _headers, body = response.finish
    assert_instance_of Facet::StreamingBody, body
  end

  def test_streamed_chunks_are_produced_in_write_order
    response = Facet::Response.new
    response.stream do |out|
      out.write('one')
      out.write('two')
    end
    _status, _headers, body = response.finish

    collected = []
    body.each { |chunk| collected << chunk }
    assert_equal %w[one two], collected
  end

  def test_assigning_a_streaming_body_directly_is_not_wrapped_in_an_array
    response = Facet::Response.new
    response.body = Facet::StreamingBody.new { |out| out.write('x') }
    assert_instance_of Facet::StreamingBody, response.body
  end

  def test_assigning_an_ordinary_string_is_still_wrapped_in_an_array
    response = Facet::Response.new
    response.body = 'plain'
    assert_equal ['plain'], response.body
  end
end
