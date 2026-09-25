require 'minitest/autorun'
require 'facet'

class RouterTest < Minitest::Test
  def setup
    @router = Facet::Router.new
  end

  def test_static_match
    @router.add('GET', '/health') {}
    matches = @router.matches('GET', '/health')
    assert_equal 1, matches.size
    assert_equal({}, matches.first[1])
  end

  def test_named_param
    @router.add('GET', '/users/:id') {}
    _, params = @router.matches('GET', '/users/42').first
    assert_equal '42', params['id']
  end

  def test_multiple_params
    @router.add('GET', '/users/:uid/posts/:pid') {}
    _, params = @router.matches('GET', '/users/7/posts/99').first
    assert_equal '7', params['uid']
    assert_equal '99', params['pid']
  end

  def test_wildcard
    @router.add('GET', '/files/*') {}
    _, params = @router.matches('GET', '/files/a/b/c.txt').first
    assert_equal ['a/b/c.txt'], params['splat']
  end

  def test_method_mismatch
    @router.add('POST', '/submit') {}
    assert_empty @router.matches('GET', '/submit')
  end

  def test_no_match
    @router.add('GET', '/x') {}
    assert_empty @router.matches('GET', '/y')
  end

  def test_param_unescape
    @router.add('GET', '/say/:word') {}
    _, params = @router.matches('GET', '/say/hello%20world').first
    assert_equal 'hello world', params['word']
  end

  def test_dot_is_literal
    @router.add('GET', '/a.b') {}
    assert_empty @router.matches('GET', '/axb')
    assert_equal 1, @router.matches('GET', '/a.b').size
  end

  def test_all_http_verbs_supported
    %w[GET POST PUT PATCH DELETE OPTIONS HEAD].each do |verb|
      @router.add(verb, '/verb-check') {}
      assert_equal 1, @router.matches(verb, '/verb-check').size, "#{verb} should match"
    end
  end

  def test_named_route_path
    @router.add('GET', '/posts/:id', name: :post) {}
    assert_equal '/posts/7', @router.path_to(:post, id: 7)
  end

  def test_named_route_path_escapes_values
    @router.add('GET', '/search/:term', name: :search) {}
    assert_equal '/search/hello%20world', @router.path_to(:search, term: 'hello world')
  end

  def test_named_route_missing_param_raises
    @router.add('GET', '/posts/:id', name: :post) {}
    assert_raises(ArgumentError) { @router.path_to(:post, {}) }
  end

  def test_unknown_named_route_raises
    assert_raises(ArgumentError) { @router.path_to(:nope) }
  end

  def test_controller_route_flag
    route = @router.add('GET', '/posts/:id', to: 'posts#show')
    assert route.controller_route?
    assert_equal 'posts', route.controller_name
    assert_equal 'show', route.action_name
  end

  def test_block_route_is_not_a_controller_route
    route = @router.add('GET', '/health') {}
    refute route.controller_route?
  end
end
