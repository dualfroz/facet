require 'minitest/autorun'
require 'facet'

class OrmErrorsJsonapiTest < Minitest::Test
  def setup
    @errors = Facet::Orm::Errors.new
  end

  def test_empty_errors_produce_empty_array
    assert_equal [], @errors.to_jsonapi
  end

  def test_one_message_becomes_one_error_object
    @errors.add(:title, "can't be blank")

    entries = @errors.to_jsonapi
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal '422', entry[:status]
    assert_equal({ pointer: '/data/attributes/title' }, entry[:source])
    assert_equal "can't be blank", entry[:title]
    assert_equal "title can't be blank", entry[:detail]
  end

  def test_custom_status_is_stringified
    @errors.add(:base, 'is stale')

    entry = @errors.to_jsonapi(status: 409).first
    assert_equal '409', entry[:status]
  end

  def test_multiple_messages_on_same_attribute_each_get_their_own_entry
    @errors.add(:body, 'is too short')
    @errors.add(:body, 'contains banned words')

    entries = @errors.to_jsonapi
    assert_equal 2, entries.size
    assert_equal ['is too short', 'contains banned words'], entries.map { |e| e[:title] }
    assert(entries.all? { |e| e[:source] == { pointer: '/data/attributes/body' } })
  end

  def test_multiple_attributes_each_produce_their_own_pointer
    @errors.add(:title, 'is too short')
    @errors.add(:user_id, 'must be present')

    entries = @errors.to_jsonapi
    pointers = entries.map { |e| e[:source][:pointer] }
    assert_includes pointers, '/data/attributes/title'
    assert_includes pointers, '/data/attributes/user_id'
  end

  def test_full_messages_and_jsonapi_detail_stay_in_sync
    @errors.add(:email, 'is invalid')

    assert_equal @errors.full_messages, @errors.to_jsonapi.map { |e| e[:detail] }
  end
end
