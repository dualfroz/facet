require 'minitest/autorun'
require 'prism'

class RouterMountTest < Minitest::Test
  def setup
    @router = Prism::Router.new
  end

  def test_finds_mount_for_exact_prefix
    app = Object.new
    @router.mount('/admin', app)
    prefix, found = @router.find_mount('/admin')
    assert_equal '/admin', prefix
    assert_same app, found
  end

  def test_finds_mount_for_nested_path
    app = Object.new
    @router.mount('/admin', app)
    prefix, found = @router.find_mount('/admin/users/1')
    assert_equal '/admin', prefix
    assert_same app, found
  end

  def test_does_not_match_sibling_path_with_shared_prefix
    app = Object.new
    @router.mount('/admin', app)
    assert_nil @router.find_mount('/administrator')
  end

  def test_returns_nil_when_no_mount_matches
    assert_nil @router.find_mount('/nowhere')
  end

  def test_trailing_slash_on_prefix_is_normalized
    app = Object.new
    @router.mount('/admin/', app)
    prefix, found = @router.find_mount('/admin/users')
    assert_equal '/admin', prefix
    assert_same app, found
  end

  def test_longest_matching_prefix_wins_when_mounts_overlap
    outer = Object.new
    inner = Object.new
    @router.mount('/api', outer)
    @router.mount('/api/v2', inner)

    _, found = @router.find_mount('/api/v2/widgets')
    assert_same inner, found

    _, found = @router.find_mount('/api/v1/widgets')
    assert_same outer, found
  end
end
