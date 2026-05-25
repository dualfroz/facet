require 'minitest/autorun'
require 'prism'

class InflectorTest < Minitest::Test
  include Prism::Inflector

  def test_underscore
    assert_equal 'posts_controller', underscore('PostsController')
    assert_equal 'html_parser', underscore('HTMLParser')
  end

  def test_camelize
    assert_equal 'PostsController', camelize('posts_controller')
  end

  def test_pluralize
    assert_equal 'posts', pluralize('post')
    assert_equal 'categories', pluralize('category')
    assert_equal 'boxes', pluralize('box')
    assert_equal 'leaves', pluralize('leaf')
  end

  def test_singularize
    assert_equal 'category', singularize('categories')
    assert_equal 'post', singularize('posts')
    assert_equal 'box', singularize('boxes')
  end

  def test_tableize
    assert_equal 'categories', tableize('Category')
    assert_equal 'posts', tableize('Post')
  end

  def test_classify
    assert_equal 'Category', classify('categories')
  end
end
