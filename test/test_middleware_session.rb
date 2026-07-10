require 'minitest/autorun'
require 'prism'
require 'support'

class MiddlewareSessionTest < Minitest::Test
  include TestSupport

  def app_for(secret:, previous_secrets: [], &handler)
    handler ||= ->(_env) { [200, {}, ['ok']] }
    Prism::Middleware::Session.new(handler, secret: secret, previous_secrets: previous_secrets)
  end

  def cookie_from(response_headers)
    line = response_headers['Set-Cookie'].split("\n").find { |entry| entry.start_with?("#{Prism::Middleware::Session::CookieName}=") }
    line.split(';').first
  end

  def test_session_written_by_one_request_is_readable_by_the_next
    write_app = app_for(secret: 's3cr3t') do |env|
      env['prism.session']['user'] = 'foksiu'
      [200, {}, ['ok']]
    end
    _, headers, = write_app.call(env_for('GET', '/'))
    cookie = cookie_from(headers)

    read_app = app_for(secret: 's3cr3t') do |env|
      [200, {}, [env['prism.session']['user']]]
    end
    _, _, body = read_app.call(env_for('GET', '/', cookies: cookie))
    assert_equal ['foksiu'], body
  end

  def test_rotated_secret_still_reads_a_session_cookie_signed_under_the_retired_one
    old_app = app_for(secret: 'old-secret') do |env|
      env['prism.session']['user'] = 'foksiu'
      [200, {}, ['ok']]
    end
    _, headers, = old_app.call(env_for('GET', '/'))
    cookie = cookie_from(headers)

    rotated_app = app_for(secret: 'new-secret', previous_secrets: ['old-secret']) do |env|
      [200, {}, [env['prism.session']['user']]]
    end
    _, _, body = rotated_app.call(env_for('GET', '/', cookies: cookie))
    assert_equal ['foksiu'], body
  end

  def test_a_secret_that_is_neither_current_nor_previous_gets_an_empty_session
    old_app = app_for(secret: 'unrelated-secret') do |env|
      env['prism.session']['user'] = 'foksiu'
      [200, {}, ['ok']]
    end
    _, headers, = old_app.call(env_for('GET', '/'))
    cookie = cookie_from(headers)

    rotated_app = app_for(secret: 'new-secret', previous_secrets: ['old-secret']) do |env|
      [200, {}, [env['prism.session']['user'].inspect]]
    end
    _, _, body = rotated_app.call(env_for('GET', '/', cookies: cookie))
    assert_equal [nil.inspect], body
  end

  def test_a_session_re_saved_after_rotation_is_signed_under_the_current_secret_only
    old_app = app_for(secret: 'old-secret') do |env|
      env['prism.session']['user'] = 'foksiu'
      [200, {}, ['ok']]
    end
    _, headers, = old_app.call(env_for('GET', '/'))
    cookie = cookie_from(headers)

    rotated_app = app_for(secret: 'new-secret', previous_secrets: ['old-secret']) do |env|
      env['prism.session']['visits'] = (env['prism.session']['visits'] || 0) + 1
      [200, {}, ['ok']]
    end
    _, rotated_headers, = rotated_app.call(env_for('GET', '/', cookies: cookie))
    re_signed_cookie = cookie_from(rotated_headers)

    new_secret_only_app = app_for(secret: 'new-secret') do |env|
      [200, {}, [env['prism.session']['user']]]
    end
    _, _, body = new_secret_only_app.call(env_for('GET', '/', cookies: re_signed_cookie))
    assert_equal ['foksiu'], body
  end
end
