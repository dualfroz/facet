require 'minitest/autorun'
require 'facet'

class RouterConstraintsTest < Minitest::Test
  def setup
    @router = Facet::Router.new
  end

  def test_constraint_accepts_matching_segment
    @router.add('GET', '/users/:id', constraints: { id: /\d+/ }) {}
    _, params = @router.matches('GET', '/users/42').first
    assert_equal '42', params['id']
  end

  def test_constraint_rejects_non_matching_segment
    @router.add('GET', '/users/:id', constraints: { id: /\d+/ }) {}
    assert_empty @router.matches('GET', '/users/not-a-number')
  end

  def test_constraint_only_applies_to_the_named_segment
    @router.add('GET', '/users/:id/posts/:slug', constraints: { id: /\d+/ }) {}
    _, params = @router.matches('GET', '/users/7/posts/hello-world').first
    assert_equal '7', params['id']
    assert_equal 'hello-world', params['slug']
    assert_empty @router.matches('GET', '/users/seven/posts/hello-world')
  end
end

class RouterFormatTest < Minitest::Test
  def setup
    @router = Facet::Router.new
  end

  def test_format_disabled_by_default_dynamic_segment_keeps_dots
    @router.add('GET', '/files/:name') {}
    _, params = @router.matches('GET', '/files/report.pdf').first
    assert_equal 'report.pdf', params['name']
    refute params.key?('format')
  end

  def test_format_enabled_extracts_extension_and_shrinks_segment
    @router.add('GET', '/posts/:id', format: true) {}
    _, params = @router.matches('GET', '/posts/7.json').first
    assert_equal '7', params['id']
    assert_equal 'json', params['format']
  end

  def test_format_enabled_still_matches_without_extension
    @router.add('GET', '/posts/:id', format: true) {}
    _, params = @router.matches('GET', '/posts/7').first
    assert_equal '7', params['id']
    refute params.key?('format')
  end

  def test_format_and_constraints_combine
    @router.add('GET', '/posts/:id', format: true, constraints: { id: /\d+/ }) {}
    _, params = @router.matches('GET', '/posts/7.xml').first
    assert_equal '7', params['id']
    assert_equal 'xml', params['format']
    assert_empty @router.matches('GET', '/posts/seven.xml')
  end

  def test_format_is_ignored_for_wildcard_patterns
    @router.add('GET', '/files/*', format: true) {}
    _, params = @router.matches('GET', '/files/a/b/report.pdf').first
    assert_equal ['a/b/report.pdf'], params['splat']
    refute params.key?('format')
  end
end
