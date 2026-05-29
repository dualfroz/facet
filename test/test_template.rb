require 'minitest/autorun'
require 'prism'

class TemplateTest < Minitest::Test
  def test_interpolation
    assert_equal 'Hello, Ruby!', Prism::Template.render('Hello, <%= name %>!', name: 'Ruby')
  end

  def test_html_escape
    result = Prism::Template.render('<%= value %>', value: '<script>alert(1)</script>')
    assert_equal '&lt;script&gt;alert(1)&lt;/script&gt;', result
  end

  def test_raw_output
    result = Prism::Template.render('<%== value %>', value: '<b>bold</b>')
    assert_equal '<b>bold</b>', result
  end

  def test_logic
    template = '<% items.each do |n| %><%= n %>;<% end %>'
    assert_equal '1;2;3;', Prism::Template.render(template, items: [1, 2, 3])
  end

  def test_conditional
    template = '<% if admin %>yes<% else %>no<% end %>'
    assert_equal 'yes', Prism::Template.render(template, admin: true)
    assert_equal 'no', Prism::Template.render(template, admin: false)
  end
end
