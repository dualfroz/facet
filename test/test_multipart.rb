require 'minitest/autorun'
require 'facet'

class MultipartTest < Minitest::Test
  BOUNDARY = '----FacetTestBoundary7331'

  def build_body(fields: {}, files: {})
    parts = fields.map do |name, value|
      "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end
    parts += files.map do |name, spec|
      filename, content_type, content = spec
      "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n" \
        "Content-Type: #{content_type}\r\n\r\n#{content}\r\n"
    end
    parts.join + "--#{BOUNDARY}--\r\n"
  end

  def test_multipart_detects_content_type
    assert Facet::Multipart.multipart?('multipart/form-data; boundary=abc')
    refute Facet::Multipart.multipart?('application/json')
    refute Facet::Multipart.multipart?(nil)
  end

  def test_boundary_from_quoted_and_bare
    assert_equal 'abc123', Facet::Multipart.boundary_from('multipart/form-data; boundary="abc123"')
    assert_equal 'abc123', Facet::Multipart.boundary_from('multipart/form-data; boundary=abc123')
    assert_nil Facet::Multipart.boundary_from('multipart/form-data')
  end

  def test_parses_plain_fields
    body = build_body(fields: { 'title' => 'hello world', 'count' => '3' })
    result = Facet::Multipart.parse(body, BOUNDARY)
    assert_equal 'hello world', result['title']
    assert_equal '3', result['count']
  end

  def test_parses_uploaded_file
    body = build_body(
      fields: { 'title' => 'my post' },
      files: { 'avatar' => ['avatar.png', 'image/png', "\x89PNG\r\ndata\x00"] }
    )
    result = Facet::Multipart.parse(body, BOUNDARY)
    assert_equal 'my post', result['title']

    file = result['avatar']
    assert_instance_of Facet::UploadedFile, file
    assert_equal 'avatar.png', file.original_filename
    assert_equal 'image/png', file.content_type
    assert_equal "\x89PNG\r\ndata\x00".b, file.read
    assert_equal file.size, File.size(file.path)
  end

  def test_binary_content_is_preserved_byte_for_byte
    binary = (0..255).map(&:chr).join.b
    body = build_body(files: { 'blob' => ['blob.bin', 'application/octet-stream', binary] })
    result = Facet::Multipart.parse(body, BOUNDARY)
    assert_equal binary, result['blob'].read
  end

  def test_array_field_names_collect_into_arrays
    parts = [
      "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"tags[]\"\r\n\r\nruby\r\n",
      "--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"tags[]\"\r\n\r\nweb\r\n",
      "--#{BOUNDARY}--\r\n"
    ]
    result = Facet::Multipart.parse(parts.join, BOUNDARY)
    assert_equal %w[ruby web], result['tags']
  end

  def test_empty_boundary_returns_empty_hash
    assert_equal({}, Facet::Multipart.parse('anything', nil))
    assert_equal({}, Facet::Multipart.parse('anything', ''))
  end

  def test_ignores_preamble_and_epilogue
    body = "this is a preamble that must be ignored\r\n" + build_body(fields: { 'a' => '1' }) + "trailing epilogue"
    result = Facet::Multipart.parse(body, BOUNDARY)
    assert_equal '1', result['a']
    assert_equal 1, result.size
  end
end
