require 'minitest/autorun'
require 'prism'
require 'support'

class ArticlePagesController < Prism::Controller
  CURRENT_ETAG = 'article-42-v3'
  CURRENT_MODIFIED = Time.utc(2026, 1, 1, 12, 0, 0)

  def show
    fresh_when(etag: CURRENT_ETAG, last_modified: CURRENT_MODIFIED)
    html('full article body')
  end

  def show_strong
    fresh_when(etag: CURRENT_ETAG, weak: false)
    html('full article body')
  end

  def edit
    if stale?(etag: CURRENT_ETAG)
      html('editable article body')
    else
      raise 'should not reach render when not stale'
    end
  end

  def update
    fresh_when(etag: CURRENT_ETAG, last_modified: CURRENT_MODIFIED)
    html('updated')
  end
end

class ConditionalGetApp < Prism::Application
  get '/article', to: 'article_pages#show'
  get '/article/strong', to: 'article_pages#show_strong'
  get '/article/edit', to: 'article_pages#edit'
  patch '/article', to: 'article_pages#update'
end

class ConditionalGetTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    ConditionalGetApp.call(env_for(method, path, **opts))
  end

  def test_first_request_renders_and_sets_etag_and_last_modified
    status, headers, body = call('GET', '/article')
    assert_equal 200, status
    assert_equal 'full article body', body.join
    refute_nil headers['ETag']
    assert_equal 'W/"' + Digest::SHA1.hexdigest('article-42-v3') + '"', headers['ETag']
    assert_equal ArticlePagesController::CURRENT_MODIFIED.httpdate, headers['Last-Modified']
  end

  def test_matching_if_none_match_returns_304_with_empty_body
    etag = 'W/"' + Digest::SHA1.hexdigest('article-42-v3') + '"'
    status, _, body = call('GET', '/article', headers: { 'If-None-Match' => etag })
    assert_equal 304, status
    assert_equal '', body.join
  end

  def test_stale_if_none_match_still_renders_with_200
    status, _, body = call('GET', '/article', headers: { 'If-None-Match' => 'W/"stale-value"' })
    assert_equal 200, status
    assert_equal 'full article body', body.join
  end

  def test_wildcard_if_none_match_is_always_fresh
    status, = call('GET', '/article', headers: { 'If-None-Match' => '*' })
    assert_equal 304, status
  end

  def test_if_modified_since_after_last_modified_is_fresh
    status, = call('GET', '/article', headers: { 'If-Modified-Since' => (ArticlePagesController::CURRENT_MODIFIED + 3600).httpdate })
    assert_equal 304, status
  end

  def test_if_modified_since_before_last_modified_is_stale
    status, _, body = call('GET', '/article', headers: { 'If-Modified-Since' => (ArticlePagesController::CURRENT_MODIFIED - 3600).httpdate })
    assert_equal 200, status
    assert_equal 'full article body', body.join
  end

  def test_strong_etag_has_no_weak_prefix
    status, headers, = call('GET', '/article/strong')
    assert_equal 200, status
    assert_equal '"' + Digest::SHA1.hexdigest('article-42-v3') + '"', headers['ETag']
  end

  def test_stale_predicate_renders_when_no_conditional_headers_sent
    status, _, body = call('GET', '/article/edit')
    assert_equal 200, status
    assert_equal 'editable article body', body.join
  end

  def test_stale_predicate_halts_with_304_and_skips_render_when_fresh
    etag = 'W/"' + Digest::SHA1.hexdigest('article-42-v3') + '"'
    status, _, body = call('GET', '/article/edit', headers: { 'If-None-Match' => etag })
    assert_equal 304, status
    assert_equal '', body.join
  end

  def test_matching_if_match_lets_the_write_through
    etag = 'W/"' + Digest::SHA1.hexdigest('article-42-v3') + '"'
    status, _, body = call('PATCH', '/article', headers: { 'If-Match' => etag })
    assert_equal 200, status
    assert_equal 'updated', body.join
  end

  def test_stale_if_match_returns_412_and_skips_the_write
    status, _, body = call('PATCH', '/article', headers: { 'If-Match' => 'W/"someone-elses-version"' })
    assert_equal 412, status
    assert_equal '', body.join
  end

  def test_wildcard_if_match_always_passes_the_precondition
    status, = call('PATCH', '/article', headers: { 'If-Match' => '*' })
    assert_equal 200, status
  end

  def test_if_unmodified_since_before_last_modified_returns_412
    header = (ArticlePagesController::CURRENT_MODIFIED - 3600).httpdate
    status, _, body = call('PATCH', '/article', headers: { 'If-Unmodified-Since' => header })
    assert_equal 412, status
    assert_equal '', body.join
  end

  def test_if_unmodified_since_at_or_after_last_modified_lets_the_write_through
    header = ArticlePagesController::CURRENT_MODIFIED.httpdate
    status, _, body = call('PATCH', '/article', headers: { 'If-Unmodified-Since' => header })
    assert_equal 200, status
    assert_equal 'updated', body.join
  end

  def test_no_precondition_headers_lets_the_write_through
    status, = call('PATCH', '/article')
    assert_equal 200, status
  end
end
