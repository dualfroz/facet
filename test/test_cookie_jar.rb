require 'minitest/autorun'
require 'prism'
require 'stringio'

class CookieJarTest < Minitest::Test
  def setup
    @secret = 'jar-secret-key'
  end

  def jar_for(cookie_header, secret: @secret, previous_secrets: [])
    env = {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/',
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new(''),
      'CONTENT_LENGTH' => '0'
    }
    env['HTTP_COOKIE'] = cookie_header if cookie_header
    request = Prism::Request.new(env)
    response = Prism::Response.new
    [Prism::CookieJar.new(request, response, secret: secret, previous_secrets: previous_secrets), response]
  end

  def test_plain_set_and_read
    jar, response = jar_for(nil)
    jar[:theme] = 'dark'
    assert_match(/theme=dark/, response['Set-Cookie'])
  end

  def test_signed_round_trip_via_two_requests
    jar, response = jar_for(nil)
    jar.signed[:user_id] = 42
    cookie_header = extract_cookie_header(response, 'user_id')

    reader_jar, = jar_for(cookie_header)
    assert_equal 42, reader_jar.signed[:user_id]
  end

  def test_signed_read_rejects_tampered_cookie
    jar, response = jar_for(nil)
    jar.signed[:user_id] = 42
    cookie_header = extract_cookie_header(response, 'user_id')
    tampered = cookie_header.sub('user_id=', 'user_id=tampered')

    reader_jar, = jar_for(tampered)
    assert_nil reader_jar.signed[:user_id]
  end

  def test_encrypted_round_trip_hides_plaintext
    jar, response = jar_for(nil)
    jar.encrypted[:secret] = 'super-sensitive-value'
    cookie_header = extract_cookie_header(response, 'secret')
    refute_includes cookie_header, 'super-sensitive-value'

    reader_jar, = jar_for(cookie_header)
    assert_equal 'super-sensitive-value', reader_jar.encrypted[:secret]
  end

  def test_encrypted_read_rejects_tampered_cookie
    jar, response = jar_for(nil)
    jar.encrypted[:secret] = 'value'
    cookie_header = extract_cookie_header(response, 'secret')
    tampered = cookie_header + 'AA'

    reader_jar, = jar_for(tampered)
    assert_nil reader_jar.encrypted[:secret]
  end

  def test_missing_cookie_returns_nil_for_signed_and_encrypted
    jar, = jar_for(nil)
    assert_nil jar.signed[:missing]
    assert_nil jar.encrypted[:missing]
  end

  def test_value_hash_form_passes_through_cookie_options
    jar, response = jar_for(nil)
    jar.signed[:remember] = { value: 'token', max_age: 3600 }
    header = response['Set-Cookie']
    assert_match(/Max-Age=3600/, header)
  end

  def test_signed_previous_secret_still_decodes_after_rotation
    old_jar, response = jar_for(nil, secret: 'old-jar-secret')
    old_jar.signed[:user_id] = 42
    cookie_header = extract_cookie_header(response, 'user_id')

    rotated_jar, = jar_for(cookie_header, secret: 'new-jar-secret', previous_secrets: ['old-jar-secret'])
    assert_equal 42, rotated_jar.signed[:user_id]
  end

  def test_encrypted_previous_secret_still_decodes_after_rotation
    old_jar, response = jar_for(nil, secret: 'old-jar-secret')
    old_jar.encrypted[:secret] = 'value-from-before-rotation'
    cookie_header = extract_cookie_header(response, 'secret')

    rotated_jar, = jar_for(cookie_header, secret: 'new-jar-secret', previous_secrets: ['old-jar-secret'])
    assert_equal 'value-from-before-rotation', rotated_jar.encrypted[:secret]
  end

  def test_signed_read_rejects_a_secret_that_was_never_current_or_previous
    old_jar, response = jar_for(nil, secret: 'unrelated-secret')
    old_jar.signed[:user_id] = 42
    cookie_header = extract_cookie_header(response, 'user_id')

    rotated_jar, = jar_for(cookie_header, secret: 'new-jar-secret', previous_secrets: ['old-jar-secret'])
    assert_nil rotated_jar.signed[:user_id]
  end

  def test_writes_after_rotation_use_the_current_secret_not_a_previous_one
    jar, response = jar_for(nil, secret: 'new-jar-secret', previous_secrets: ['old-jar-secret'])
    jar.signed[:user_id] = 42
    cookie_header = extract_cookie_header(response, 'user_id')

    reader_on_old_secret_only, = jar_for(cookie_header, secret: 'old-jar-secret')
    assert_nil reader_on_old_secret_only.signed[:user_id]
  end

  private

  def extract_cookie_header(response, name)
    line = response['Set-Cookie'].split("\n").find { |entry| entry.start_with?("#{name}=") }
    line.split(';').first
  end
end
