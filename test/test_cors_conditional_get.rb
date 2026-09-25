require 'minitest/autorun'
require 'facet'
require 'support'

class CorsArticlesController < Facet::Controller
  ETAG = 'cors-article-v1'.freeze

  def show
    fresh_when(etag: ETAG)
    html('full article body')
  end
end

class CorsConditionalGetApp < Facet::Application
  get '/api/articles/1', to: 'cors_articles#show'
end

class CorsConditionalGetTest < Minitest::Test
  include TestSupport

  ORIGIN = 'https://app.example.com'.freeze
  FRESH_ETAG = 'W/"' + Digest::SHA1.hexdigest(CorsArticlesController::ETAG) + '"'

  def setup
    Facet::Cors.reset!
    Facet::Cors.configure do |config|
      config.allow do
        origins ORIGIN
        resource '/api/*', methods: %w[GET]
      end
    end
    @app = Facet::Middleware::Cors.new(CorsConditionalGetApp)
  end

  def teardown
    Facet::Cors.reset!
  end

  def call(headers)
    @app.call(env_for('GET', '/api/articles/1', headers: headers))
  end

  def test_first_cross_origin_request_renders_and_still_gets_cors_headers
    status, headers, body = call('Origin' => ORIGIN)

    assert_equal 200, status
    assert_equal 'full article body', body.join
    assert_equal FRESH_ETAG, headers['ETag']
    assert_equal ORIGIN, headers['Access-Control-Allow-Origin']
    assert_equal 'Origin', headers['Vary']
  end

  def test_fresh_cross_origin_request_gets_304_with_cors_headers_intact
    status, headers, body = call('Origin' => ORIGIN, 'If-None-Match' => FRESH_ETAG)

    assert_equal 304, status
    assert_equal '', body.join
    assert_equal FRESH_ETAG, headers['ETag'], 'ETag must still be set on a 304, the client needs it to keep caching'
    assert_equal ORIGIN, headers['Access-Control-Allow-Origin'],
                 'a 304 short-circuited by halt() must not lose the CORS headers Cors already knows to stamp on any status'
    assert_equal 'Origin', headers['Vary']
  end

  def test_fresh_same_origin_request_gets_304_without_cors_headers
    status, headers, body = call('If-None-Match' => FRESH_ETAG)

    assert_equal 304, status
    assert_equal '', body.join
    assert_equal FRESH_ETAG, headers['ETag']
    assert_nil headers['Access-Control-Allow-Origin']
  end

  def test_stale_cross_origin_request_from_a_disallowed_origin_still_renders_without_cors_headers
    status, headers, body = call('Origin' => 'https://evil.example.com', 'If-None-Match' => FRESH_ETAG)

    assert_equal 304, status, 'ConditionalGet does not know or care about CORS - freshness alone decides the status'
    assert_equal '', body.join
    assert_nil headers['Access-Control-Allow-Origin']
  end
end
