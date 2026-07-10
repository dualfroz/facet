require 'minitest/autorun'
require 'prism'
require 'support'

class MiddlewareCorsTest < Minitest::Test
  include TestSupport

  def setup
    Prism::Cors.reset!
    @downstream_calls = 0
    downstream = lambda do |_env|
      @downstream_calls += 1
      [200, {'Content-Type' => 'application/json'}, ['{}']]
    end
    @app = Prism::Middleware::Cors.new(downstream)
  end

  def teardown
    Prism::Cors.reset!
  end

  def configure_api(**resource_options)
    Prism::Cors.configure do |config|
      config.allow do
        origins 'https://app.example.com'
        resource '/api/*', **resource_options
      end
    end
  end

  def test_request_without_origin_header_passes_through_untouched
    status, headers, = @app.call(env_for('GET', '/api/posts'))
    assert_equal 200, status
    assert_nil headers['Access-Control-Allow-Origin']
    assert_equal 1, @downstream_calls
  end

  def test_request_with_unmatched_origin_passes_through_without_cors_headers
    configure_api(methods: %w[GET])
    env = env_for('GET', '/api/posts', headers: {'Origin' => 'https://evil.example.com'})
    status, headers, = @app.call(env)
    assert_equal 200, status
    assert_nil headers['Access-Control-Allow-Origin']
    assert_equal 1, @downstream_calls
  end

  def test_simple_request_with_allowed_origin_gets_cors_headers_and_reaches_the_app
    configure_api(methods: %w[GET])
    env = env_for('GET', '/api/posts', headers: {'Origin' => 'https://app.example.com'})
    status, headers, = @app.call(env)

    assert_equal 200, status
    assert_equal 'https://app.example.com', headers['Access-Control-Allow-Origin']
    assert_equal 'Origin', headers['Vary']
    assert_equal 1, @downstream_calls
  end

  def test_preflight_request_is_answered_directly_without_reaching_the_app
    configure_api(methods: %w[GET POST], headers: %w[Content-Type])
    env = env_for('OPTIONS', '/api/posts', headers: {
      'Origin' => 'https://app.example.com',
      'Access-Control-Request-Method' => 'POST',
      'Access-Control-Request-Headers' => 'Content-Type'
    })
    status, headers, body = @app.call(env)

    assert_equal 204, status
    assert_equal 'https://app.example.com', headers['Access-Control-Allow-Origin']
    assert_equal 'GET, POST', headers['Access-Control-Allow-Methods']
    assert_equal 'Content-Type', headers['Access-Control-Allow-Headers']
    assert_empty body
    assert_equal 0, @downstream_calls
  end

  def test_preflight_with_disallowed_method_is_rejected
    configure_api(methods: %w[GET])
    env = env_for('OPTIONS', '/api/posts', headers: {
      'Origin' => 'https://app.example.com',
      'Access-Control-Request-Method' => 'DELETE'
    })
    status, = @app.call(env)

    assert_equal 403, status
    assert_equal 0, @downstream_calls
  end

  def test_preflight_with_disallowed_header_is_rejected
    configure_api(methods: %w[POST], headers: %w[Content-Type])
    env = env_for('OPTIONS', '/api/posts', headers: {
      'Origin' => 'https://app.example.com',
      'Access-Control-Request-Method' => 'POST',
      'Access-Control-Request-Headers' => 'X-Secret'
    })
    status, = @app.call(env)

    assert_equal 403, status
  end

  def test_max_age_is_only_sent_when_configured
    configure_api(methods: %w[GET], max_age: 600)
    env = env_for('OPTIONS', '/api/posts', headers: {
      'Origin' => 'https://app.example.com',
      'Access-Control-Request-Method' => 'GET'
    })
    _, headers, = @app.call(env)
    assert_equal '600', headers['Access-Control-Max-Age']
  end

  def test_credentials_true_echoes_origin_and_sets_allow_credentials
    configure_api(methods: %w[GET], credentials: true)
    env = env_for('GET', '/api/posts', headers: {'Origin' => 'https://app.example.com'})
    _, headers, = @app.call(env)

    assert_equal 'https://app.example.com', headers['Access-Control-Allow-Origin']
    assert_equal 'true', headers['Access-Control-Allow-Credentials']
  end

  def test_expose_headers_only_sent_when_configured
    configure_api(methods: %w[GET], expose: %w[X-Total-Count])
    env = env_for('GET', '/api/posts', headers: {'Origin' => 'https://app.example.com'})
    _, headers, = @app.call(env)
    assert_equal 'X-Total-Count', headers['Access-Control-Expose-Headers']
  end

  def test_vary_origin_is_appended_to_an_existing_vary_header
    Prism::Cors.reset!
    downstream = lambda { |_env| [200, {'Vary' => 'Accept'}, ['{}']] }
    app = Prism::Middleware::Cors.new(downstream)
    configure_api(methods: %w[GET])
    env = env_for('GET', '/api/posts', headers: {'Origin' => 'https://app.example.com'})
    _, headers, = app.call(env)
    assert_equal 'Accept, Origin', headers['Vary']
  end

  def test_a_resource_registered_without_a_format_extension_still_matches_a_dot_json_path
    configure_api(methods: %w[GET])
    env = env_for('GET', '/api/posts.json', headers: {'Origin' => 'https://app.example.com'})
    status, headers, = @app.call(env)
    assert_equal 200, status
    assert_equal 'https://app.example.com', headers['Access-Control-Allow-Origin']
  end

  def test_options_without_request_method_header_is_treated_as_a_simple_request
    configure_api(methods: %w[GET])
    env = env_for('OPTIONS', '/api/posts', headers: {'Origin' => 'https://app.example.com'})
    status, = @app.call(env)
    assert_equal 200, status
    assert_equal 1, @downstream_calls
  end
end
