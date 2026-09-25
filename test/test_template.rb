require 'minitest/autorun'
require 'facet'

class TemplateTest < Minitest::Test
  def test_interpolation
    assert_equal 'Hello, Ruby!', Facet::Template.render('Hello, <%= name %>!', name: 'Ruby')
  end

  def test_html_escape
    result = Facet::Template.render('<%= value %>', value: '<script>alert(1)</script>')
    assert_equal '&lt;script&gt;alert(1)&lt;/script&gt;', result
  end

  def test_raw_output
    result = Facet::Template.render('<%== value %>', value: '<b>bold</b>')
    assert_equal '<b>bold</b>', result
  end

  def test_logic
    template = '<% items.each do |n| %><%= n %>;<% end %>'
    assert_equal '1;2;3;', Facet::Template.render(template, items: [1, 2, 3])
  end

  def test_conditional
    template = '<% if admin %>yes<% else %>no<% end %>'
    assert_equal 'yes', Facet::Template.render(template, admin: true)
    assert_equal 'no', Facet::Template.render(template, admin: false)
  end
end
