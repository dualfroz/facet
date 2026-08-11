require 'minitest/autorun'
require 'prism'

class StrongParametersTest < Minitest::Test
  def test_require_returns_value_for_present_key
    params = Prism::StrongParameters.new('user' => { 'name' => 'ann' })
    user = params.require('user')
    assert_kind_of Prism::StrongParameters, user
  end

  def test_require_raises_when_missing
    params = Prism::StrongParameters.new({})
    assert_raises(Prism::StrongParameters::ParameterMissing) { params.require('user') }
  end

  def test_require_raises_when_blank
    params = Prism::StrongParameters.new('name' => '')
    assert_raises(Prism::StrongParameters::ParameterMissing) { params.require('name') }
  end

  def test_permit_allows_only_listed_scalar_keys
    params = Prism::StrongParameters.new('name' => 'ann', 'admin' => true)
    permitted = params.permit(:name)
    assert_equal({ 'name' => 'ann' }, permitted.to_h)
  end

  def test_permit_drops_unlisted_hash_and_array_values_even_if_named
    params = Prism::StrongParameters.new('name' => 'ann', 'profile' => { 'bio' => 'x' })
    permitted = params.permit(:name, :profile)
    assert_equal({ 'name' => 'ann' }, permitted.to_h)
  end

  def test_permit_nested_hash_with_sub_filters
    params = Prism::StrongParameters.new(
      'user' => { 'name' => 'ann', 'admin' => true, 'address' => { 'city' => 'nyc', 'secret' => 'x' } }
    )
    permitted = params.require('user').permit(:name, address: [:city])
    assert_equal({ 'name' => 'ann', 'address' => { 'city' => 'nyc' } }, permitted.to_h)
  end

  def test_permit_array_of_scalars_with_empty_filter
    params = Prism::StrongParameters.new('tags' => %w[ruby web])
    permitted = params.permit(tags: [])
    assert_equal({ 'tags' => %w[ruby web] }, permitted.to_h)
  end

  def test_permit_array_of_hashes_with_sub_filters
    params = Prism::StrongParameters.new(
      'items' => [{ 'sku' => 'a1', 'cost' => 5 }, { 'sku' => 'a2', 'cost' => 9 }]
    )
    permitted = params.permit(items: [:sku])
    assert_equal({ 'items' => [{ 'sku' => 'a1' }, { 'sku' => 'a2' }] }, permitted.to_h)
  end

  # A real HTML form built from Prism::Params.nested_from's bracket
  # expansion (accepts_nested_attributes_for style "post[comments_attributes]
  # [0][body]" field names) never arrives as an Array - it arrives as a Hash
  # keyed by the string indices "0", "1". permit must recognize that shape
  # and allowlist each entry the same way it would for a real Array,
  # otherwise every nested-attributes submission silently collapses to {}.
  def test_permit_indexed_hash_of_hashes_behaves_like_an_array_of_hashes
    params = Prism::StrongParameters.new(
      'comments_attributes' => {
        '0' => { 'id' => '1', 'body' => 'a', 'secret' => 'x' },
        '1' => { 'body' => 'b' }
      }
    )
    permitted = params.permit(comments_attributes: %i[id body _destroy])
    assert_equal(
      { 'comments_attributes' => { '0' => { 'id' => '1', 'body' => 'a' }, '1' => { 'body' => 'b' } } },
      permitted.to_h
    )
  end

  def test_permit_nested_hash_with_non_numeric_keys_is_not_treated_as_indexed
    params = Prism::StrongParameters.new('address' => { 'city' => 'nyc', 'secret' => 'x' })
    permitted = params.permit(address: [:city])
    assert_equal({ 'address' => { 'city' => 'nyc' } }, permitted.to_h)
  end

  def test_to_h_raises_when_not_permitted
    params = Prism::StrongParameters.new('name' => 'ann')
    assert_raises(Prism::StrongParameters::UnfilteredParameters) { params.to_h }
  end

  def test_to_unsafe_h_works_regardless_of_permitted_state
    params = Prism::StrongParameters.new('name' => 'ann')
    assert_equal({ 'name' => 'ann' }, params.to_unsafe_h)
  end

  def test_symbol_and_string_keys_are_interchangeable
    params = Prism::StrongParameters.new(name: 'ann')
    assert_equal 'ann', params[:name]
    assert_equal 'ann', params['name']
  end

  def test_params_permit_and_require_delegate_to_strong_parameters
    params = Prism::Params.from('user' => { 'name' => 'ann', 'admin' => true })
    permitted = params.require('user').permit(:name)
    assert_equal({ 'name' => 'ann' }, permitted.to_h)
  end
end
