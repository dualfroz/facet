require 'minitest/autorun'
require 'prism'

class FormForHelperTest < Minitest::Test
  FakeModel = Struct.new(:id, :title) do
    def persisted?
      !id.nil?
    end
  end

  HelpersWithCsrf = Struct.new(:csrf_token)

  def render(source, helpers = nil)
    Prism::Template.render(source, {}, nil, helpers)
  end

  def test_form_for_new_record_uses_post
    html = render(<<~ERB)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts") do |f| %>
      <%== f.text_field(:title) %>
      <% end %>
    ERB
    assert_includes html, '<form action="/posts" method="post">'
    refute_includes html, '_method'
    assert_includes html, 'name="fake_model[title]"'
    assert_includes html, '</form>'
  end

  def test_form_for_persisted_record_defaults_to_patch_via_method_override
    html = render(<<~ERB)
      <% form_for(FormForHelperTest::FakeModel.new(1, "hi"), url: "/posts/1") do |f| %>
      <%== f.submit %>
      <% end %>
    ERB
    assert_includes html, '<form action="/posts/1" method="post">'
    assert_includes html, '<input type="hidden" name="_method" value="PATCH">'
  end

  def test_form_for_explicit_method_delete
    html = render(<<~ERB)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts/1", method: :delete) do |f| %>
      <% end %>
    ERB
    assert_includes html, '<input type="hidden" name="_method" value="DELETE">'
  end

  def test_form_for_embeds_csrf_token_when_helpers_provide_one
    helpers = HelpersWithCsrf.new('secrettoken')
    html = render(<<~ERB, helpers)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts") do |f| %>
      <% end %>
    ERB
    assert_includes html, '<input type="hidden" name="authenticity_token" value="secrettoken">'
  end

  def test_form_for_without_helpers_has_no_csrf_field
    html = render(<<~ERB)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts") do |f| %>
      <% end %>
    ERB
    refute_includes html, 'authenticity_token'
  end

  def test_form_for_get_has_no_csrf_field
    helpers = HelpersWithCsrf.new('secrettoken')
    html = render(<<~ERB, helpers)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts", method: :get) do |f| %>
      <% end %>
    ERB
    refute_includes html, 'authenticity_token'
  end

  def test_content_between_form_fields_is_placed_in_order
    html = render(<<~ERB)
      <% form_for(FormForHelperTest::FakeModel.new, url: "/posts") do |f| %>
      <%== f.label(:title) %>
      <%== f.text_field(:title) %>
      <% end %>
    ERB
    assert html.index('<label') < html.index('<input')
    assert html.index('<input') < html.index('</form>')
  end
end
