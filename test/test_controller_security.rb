require 'minitest/autorun'
require 'prism'
require 'support'

class NotesController < Prism::Controller
  protect_from_forgery except: [:token]

  def self.received_log
    @received_log ||= []
  end

  def token
    html(csrf_token)
  end

  def create
    self.class.received_log << params['title']
    halt(201, JSON.generate(ok: true))
  end

  def write_cookie
    cookies.signed[:uid] = 42
    cookies.encrypted[:secret_note] = 'top secret'
    halt(200, 'stored')
  end

  def read_cookie
    halt(200, JSON.generate(uid: cookies.signed[:uid], note: cookies.encrypted[:secret_note]))
  end

  def read_raw_cookie
    halt(200, JSON.generate(raw: cookies['uid']))
  end
end

class SecureNotesApp < Prism::Application
  enable_sessions(secret: 'notes-secret')

  get '/notes/token', to: 'notes#token'
  post '/notes', to: 'notes#create'
  get '/notes/cookie', to: 'notes#write_cookie'
  get '/notes/read_cookie', to: 'notes#read_cookie'
  get '/notes/read_raw_cookie', to: 'notes#read_raw_cookie'
end

class ControllerSecurityTest < Minitest::Test
  include TestSupport

  def setup
    NotesController.received_log.clear
  end

  def call(method, path, **opts)
    SecureNotesApp.call(env_for(method, path, **opts))
  end

  def session_cookie_from(headers)
    line = headers['Set-Cookie'].split("\n").find { |c| c.start_with?('prism.session=') }
    line.split(';').first
  end

  def test_post_without_authenticity_token_is_rejected
    status, = call('POST', '/notes', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                      body: 'title=hi')
    assert_equal 422, status
    assert_equal [], NotesController.received_log
  end

  def test_post_with_valid_authenticity_token_is_accepted
    _, headers, body = call('GET', '/notes/token')
    token = body.join
    cookie = session_cookie_from(headers)

    status, = call('POST', '/notes',
                    headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                    cookies: cookie,
                    body: "title=hi&authenticity_token=#{CGI.escape(token)}")
    assert_equal 201, status
    assert_equal ['hi'], NotesController.received_log
  end

  def test_post_with_token_from_a_different_session_is_rejected
    _, other_headers, other_body = call('GET', '/notes/token')
    other_token = other_body.join
    refute_nil session_cookie_from(other_headers)

    _, first_headers, = call('GET', '/notes/token')
    first_cookie = session_cookie_from(first_headers)

    status, = call('POST', '/notes',
                    headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                    cookies: first_cookie,
                    body: "title=hi&authenticity_token=#{CGI.escape(other_token)}")
    assert_equal 422, status
  end

  def test_signed_and_encrypted_cookies_round_trip_through_a_real_request_cycle
    _, write_headers, = call('GET', '/notes/cookie')
    lines = write_headers['Set-Cookie'].split("\n")
    cookie_header = lines.map { |line| line.split(';').first }.join('; ')

    _, _, body = call('GET', '/notes/read_cookie', cookies: cookie_header)
    parsed = JSON.parse(body.join)
    assert_equal 42, parsed['uid']
    assert_equal 'top secret', parsed['note']
  end

  def test_signed_cookie_value_is_not_stored_in_plaintext
    _, write_headers, = call('GET', '/notes/cookie')
    lines = write_headers['Set-Cookie'].split("\n")
    cookie_header = lines.map { |line| line.split(';').first }.join('; ')

    _, _, body = call('GET', '/notes/read_raw_cookie', cookies: cookie_header)
    raw = JSON.parse(body.join)['raw']
    refute_nil raw
    refute_equal '42', raw
  end
end
