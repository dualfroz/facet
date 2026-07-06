require 'minitest/autorun'
require 'prism'

class CorsDslTest < Minitest::Test
  def setup
    Prism::Cors.reset!
  end

  def teardown
    Prism::Cors.reset!
  end

  def test_matches_allowed_origin_and_resource_pattern
    Prism::Cors.configure do |config|
      config.allow do
        origins 'https://app.example.com'
        resource '/api/*', methods: %w[GET POST]
      end
    end

    rule, resource = Prism::Cors.resource_for('https://app.example.com', '/api/posts')
    refute_nil rule
    assert_equal %w[GET POST], resource.methods
  end

  def test_unmatched_origin_returns_nil
    Prism::Cors.configure do |config|
      config.allow do
        origins 'https://app.example.com'
        resource '/api/*'
      end
    end

    assert_nil Prism::Cors.resource_for('https://evil.example.com', '/api/posts')
  end

  def test_unmatched_path_returns_nil_even_with_allowed_origin
    Prism::Cors.configure do |config|
      config.allow do
        origins 'https://app.example.com'
        resource '/api/*'
      end
    end

    assert_nil Prism::Cors.resource_for('https://app.example.com', '/admin/secrets')
  end

  def test_wildcard_origin_matches_anything
    Prism::Cors.configure do |config|
      config.allow do
        origins '*'
        resource '/public/*'
      end
    end

    refute_nil Prism::Cors.resource_for('https://anyone.example.com', '/public/feed')
  end

  def test_regexp_origin_matches
    Prism::Cors.configure do |config|
      config.allow do
        origins(/\Ahttps:\/\/.*\.example\.com\z/)
        resource '/api/*'
      end
    end

    refute_nil Prism::Cors.resource_for('https://sub.example.com', '/api/posts')
    assert_nil Prism::Cors.resource_for('https://sub.example.org', '/api/posts')
  end

  def test_first_matching_rule_wins_when_multiple_rules_allow_the_origin
    Prism::Cors.configure do |config|
      config.allow do
        origins '*'
        resource '/api/*', methods: %w[GET]
      end
      config.allow do
        origins '*'
        resource '/api/*', methods: %w[GET POST DELETE]
      end
    end

    _rule, resource = Prism::Cors.resource_for('https://x.example.com', '/api/posts')
    assert_equal %w[GET], resource.methods
  end

  def test_reset_clears_every_rule
    Prism::Cors.configure { |config| config.allow { origins '*'; resource '/api/*' } }
    Prism::Cors.reset!
    assert_empty Prism::Cors.configuration.rules
  end
end

class CorsResourceTest < Minitest::Test
  def test_allows_headers_any_accepts_everything
    resource = Prism::Cors::Resource.new('/api/*', headers: :any)
    assert resource.allows_headers?('X-Custom-Header, Authorization')
  end

  def test_allows_headers_checks_each_requested_header_case_insensitively
    resource = Prism::Cors::Resource.new('/api/*', headers: %w[Authorization X-Request-Id])
    assert resource.allows_headers?('authorization, x-request-id')
    refute resource.allows_headers?('authorization, x-secret')
  end

  def test_allows_headers_with_blank_request_is_always_true
    resource = Prism::Cors::Resource.new('/api/*', headers: %w[Authorization])
    assert resource.allows_headers?(nil)
    assert resource.allows_headers?('')
  end

  def test_allows_method_is_case_insensitive_on_registration
    resource = Prism::Cors::Resource.new('/api/*', methods: %w[get post])
    assert resource.allows_method?('GET')
    assert resource.allows_method?('post')
    refute resource.allows_method?('DELETE')
  end
end
