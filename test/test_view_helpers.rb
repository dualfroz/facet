require 'minitest/autorun'
require 'facet'

class ViewHelpersTest < Minitest::Test
  def render(source, locals = {}, helpers = nil)
    Facet::Template.render(source, locals, nil, helpers)
  end

  def test_tag_renders_void_element
    assert_equal '<br class="hint">', render('<%== tag(:br, class: "hint") %>')
  end

  def test_tag_omits_false_and_nil_attributes
    assert_equal '<input>', render('<%== tag(:input, disabled: false, value: nil) %>')
  end

  def test_tag_boolean_true_attribute_renders_itself
    assert_equal '<input disabled="disabled">', render('<%== tag(:input, disabled: true) %>')
  end

  def test_content_tag_without_block_escapes_content
    result = render('<%== content_tag(:p, "<b>hi</b>") %>')
    assert_equal '<p>&lt;b&gt;hi&lt;/b&gt;</p>', result
  end

  def test_content_tag_with_block_appends_inline_and_nests
    template = '<% content_tag(:div, class: "wrap") do %><%= "safe & sound" %><% end %>'
    assert_equal '<div class="wrap">safe &amp; sound</div>', render(template)
  end

  def test_content_tag_block_form_can_nest_helpers
    template = <<~ERB
      <% content_tag(:div) do %>
      <%== link_to("Home", "/") %>
      <% end %>
    ERB
    result = render(template)
    assert_includes result, '<div>'
    assert_includes result, '<a href="/">Home</a>'
    assert result.index('<div>') < result.index('<a href="/">')
  end

  def test_link_to_builds_anchor
    assert_equal '<a href="/posts">Posts</a>', render('<%== link_to("Posts", "/posts") %>')
  end

  def test_link_to_escapes_text
    assert_equal '<a href="/x">&lt;script&gt;</a>', render('<%== link_to("<script>", "/x") %>')
  end

  def test_button_to_wraps_a_form_with_hidden_method_and_submit
    html = render('<%== button_to("Delete", "/posts/1", method: :delete) %>')
    assert_includes html, '<form action="/posts/1" method="post"'
    assert_includes html, '<input type="hidden" name="_method" value="DELETE">'
    assert_includes html, '<button type="submit">Delete</button>'
  end

  def test_button_to_plain_post_has_no_method_override
    html = render('<%== button_to("Go", "/go") %>')
    refute_includes html, '_method'
  end

  def test_helper_delegates_to_supplied_helpers_object
    helpers = Struct.new(:csrf_token).new('tok123')
    html = render('<%== link_to(csrf_token, "/x") %>', {}, helpers)
    assert_equal '<a href="/x">tok123</a>', html
  end
end
