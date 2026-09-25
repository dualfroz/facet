require 'minitest/autorun'
require 'facet'
require 'support'

class ScopedIndexController < Facet::Controller
  def buggy_index
    viewer = request.env['HTTP_X_TEST_USER']
    fresh_when(etag: ['same-page-content'])
    html(viewer ? "signed in as #{viewer}" : 'anonymous visitor')
  end

  def fixed_index
    viewer = request.env['HTTP_X_TEST_USER']
    fresh_when(etag: ['same-page-content', viewer])
    html(viewer ? "signed in as #{viewer}" : 'anonymous visitor')
  end
end

class ScopedIndexApp < Facet::Application
  get '/buggy', to: 'scoped_index#buggy_index'
  get '/fixed', to: 'scoped_index#fixed_index'
end

class ConditionalGetUserScopedEtagTest < Minitest::Test
  include TestSupport

  def call(path, headers = {})
    ScopedIndexApp.call(env_for('GET', path, headers: headers))
  end

  def test_buggy_etag_is_identical_across_different_viewers
    _, anon_headers, = call('/buggy')
    _, alice_headers, = call('/buggy', 'X-Test-User' => 'alice')

    assert_equal anon_headers['ETag'], alice_headers['ETag'],
                 'demonstrates the bug: rendered content differs by viewer but the etag does not'
  end

  def test_buggy_etag_lets_a_cached_signed_in_body_leak_back_to_an_anonymous_request
    _, alice_headers, alice_body = call('/buggy', 'X-Test-User' => 'alice')
    assert_equal 'signed in as alice', alice_body.join

    status, _, anon_body = call('/buggy', 'If-None-Match' => alice_headers['ETag'])
    assert_equal 304, status,
                 "the bug: an anonymous visitor whose If-None-Match happens to equal alice's is told nothing changed"
    assert_equal '', anon_body.join
  end

  def test_fixed_etag_differs_by_viewer
    _, anon_headers, = call('/fixed')
    _, alice_headers, = call('/fixed', 'X-Test-User' => 'alice')

    refute_equal anon_headers['ETag'], alice_headers['ETag']
  end

  def test_fixed_etag_never_returns_a_304_across_different_viewers
    _, alice_headers, = call('/fixed', 'X-Test-User' => 'alice')

    status, _, anon_body = call('/fixed', 'If-None-Match' => alice_headers['ETag'])
    assert_equal 200, status, "an anonymous visitor must get a fresh render, never alice's cached 304"
    assert_equal 'anonymous visitor', anon_body.join
  end

  def test_fixed_etag_still_returns_304_for_the_same_viewer
    _, alice_headers, = call('/fixed', 'X-Test-User' => 'alice')

    status, headers, body = call('/fixed', 'X-Test-User' => 'alice', 'If-None-Match' => alice_headers['ETag'])
    assert_equal 304, status
    assert_equal '', body.join
    assert_equal alice_headers['ETag'], headers['ETag']
  end
end
