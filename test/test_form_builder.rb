require 'minitest/autorun'
require 'facet'

class FormBuilderTest < Minitest::Test
  FakeErrors = Struct.new(:store) do
    def [](attribute)
      store.fetch(attribute, [])
    end
  end

  FakeModel = Struct.new(:id, :title, :published, :errors, :comments) do
    def persisted?
      !id.nil?
    end
  end

  FakeComment = Struct.new(:id, :body, :errors)

  def new_post(title: 'Hello', published: false, id: nil, errors: {}, comments: [])
    FakeModel.new(id, title, published, FakeErrors.new(errors), comments)
  end

  def new_comment(id:, body:)
    FakeComment.new(id, body, FakeErrors.new({}))
  end

  def builder_for(model, object_name: nil)
    Facet::FormBuilder.new(model, object_name: object_name)
  end

  def test_text_field_uses_rails_style_nested_name_and_id
    html = builder_for(new_post).text_field(:title)
    assert_equal '<input type="text" name="fake_model[title]" id="fake_model_title" value="Hello">', html
  end

  def test_text_field_value_can_be_overridden
    html = builder_for(new_post).text_field(:title, value: 'Overridden')
    assert_includes html, 'value="Overridden"'
  end

  def test_text_field_escapes_value
    html = builder_for(new_post(title: '<b>')).text_field(:title)
    assert_includes html, 'value="&lt;b&gt;"'
  end

  def test_label_defaults_to_humanized_attribute
    html = builder_for(new_post).label(:title)
    assert_equal '<label for="fake_model_title">Title</label>', html
  end

  def test_label_accepts_custom_text
    html = builder_for(new_post).label(:title, 'Post title')
    assert_includes html, '>Post title</label>'
  end

  def test_hidden_field
    html = builder_for(new_post(id: 7)).hidden_field(:id)
    assert_equal '<input type="hidden" name="fake_model[id]" id="fake_model_id" value="7">', html
  end

  def test_text_area_renders_content_between_tags_not_as_value_attribute
    html = builder_for(new_post(title: "multi\nline")).text_area(:title)
    assert_equal "<textarea name=\"fake_model[title]\" id=\"fake_model_title\">multi\nline</textarea>", html
  end

  def test_check_box_emits_hidden_fallback_and_reflects_current_value
    html = builder_for(new_post(published: true)).check_box(:published)
    assert_includes html, 'name="fake_model[published]" value="0"'
    assert_includes html, 'type="checkbox"'
    assert_includes html, 'checked="checked"'
  end

  def test_check_box_unchecked_when_value_falsey
    html = builder_for(new_post(published: false)).check_box(:published)
    refute_includes html, 'checked'
  end

  def test_select_marks_current_value_selected
    html = builder_for(new_post(title: 'b')).select(:title, %w[a b c])
    assert_includes html, '<option value="a">a</option>'
    assert_includes html, '<option value="b" selected="selected">b</option>'
  end

  def test_select_with_label_value_pairs
    html = builder_for(new_post(title: '2')).select(:title, [['One', '1'], ['Two', '2']])
    assert_includes html, '<option value="2" selected="selected">Two</option>'
  end

  def test_select_include_blank
    html = builder_for(new_post).select(:title, %w[a b], include_blank: true)
    assert_includes html, '<option value=""></option>'
  end

  def test_submit_default_and_custom_value
    assert_equal '<input type="submit" value="Save">', builder_for(new_post).submit
    assert_equal '<input type="submit" value="Go">', builder_for(new_post).submit('Go')
  end

  def test_errors_for_reads_from_object_errors
    model = new_post(errors: { title: ['is too short'] })
    assert_equal ['is too short'], builder_for(model).errors_for(:title)
  end

  def test_error_messages_renders_wrapper_only_when_present
    clean = builder_for(new_post)
    assert_equal '', clean.error_messages(:title)

    dirty = builder_for(new_post(errors: { title: ['is blank', 'is too short'] }))
    assert_equal '<span class="field-error">is blank, is too short</span>', dirty.error_messages(:title)
  end

  def test_object_name_can_be_overridden
    html = builder_for(new_post, object_name: :post).text_field(:title)
    assert_includes html, 'name="post[title]"'
    assert_includes html, 'id="post_title"'
  end

  def test_fields_for_yields_one_nested_builder_per_record_with_indexed_names
    post = new_post(id: 1, comments: [new_comment(id: 10, body: 'first'), new_comment(id: 11, body: 'second')])
    builder = builder_for(post, object_name: :post)

    rendered = []
    builder.fields_for(:comments) { |f| rendered << f.text_field(:body) }

    assert_equal 2, rendered.size
    assert_equal '<input type="text" name="post[comments_attributes][0][body]" ' \
                 'id="post_comments_attributes_0_body" value="first">', rendered[0]
    assert_equal '<input type="text" name="post[comments_attributes][1][body]" ' \
                 'id="post_comments_attributes_1_body" value="second">', rendered[1]
  end

  def test_fields_for_hidden_id_carries_the_record_id
    post = new_post(id: 1, comments: [new_comment(id: 42, body: 'x')])
    builder = builder_for(post, object_name: :post)

    html = nil
    builder.fields_for(:comments) { |f| html = f.hidden_field(:id) }
    assert_equal '<input type="hidden" name="post[comments_attributes][0][id]" ' \
                 'id="post_comments_attributes_0_id" value="42">', html
  end

  def test_fields_for_accepts_an_explicit_collection_override
    post = new_post(id: 1)
    builder = builder_for(post, object_name: :post)

    seen = []
    builder.fields_for(:comments, [new_comment(id: 5, body: 'explicit')]) { |f| seen << f.object.id }
    assert_equal [5], seen
  end
end
