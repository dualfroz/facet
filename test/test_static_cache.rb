require 'minitest/autorun'
require 'facet'

class StaticCacheTest < Minitest::Test
  def test_weak_validators_are_size_and_mtime
    mtime = Time.at(1_700_000_000)
    etag, last_modified = Facet::StaticCache.weak_validators(42, mtime)

    assert_equal 'W/"42-1700000000"', etag
    assert_equal mtime.utc.httpdate, last_modified
  end

  def test_strong_etag_is_quoted_hash
    assert_equal '"deadbeef"', Facet::StaticCache.strong_etag('deadbeef')
  end

  def test_not_modified_true_when_if_none_match_matches
    env = { 'HTTP_IF_NONE_MATCH' => '"abc"' }
    assert Facet::StaticCache.not_modified?(env, '"abc"', nil)
  end

  def test_not_modified_true_on_wildcard_if_none_match
    env = { 'HTTP_IF_NONE_MATCH' => '*' }
    assert Facet::StaticCache.not_modified?(env, '"anything"', nil)
  end

  def test_not_modified_false_when_etag_differs
    env = { 'HTTP_IF_NONE_MATCH' => '"abc"' }
    refute Facet::StaticCache.not_modified?(env, '"xyz"', nil)
  end

  def test_not_modified_true_when_if_modified_since_not_older
    last_modified = Time.at(1_700_000_000).utc.httpdate
    env = { 'HTTP_IF_MODIFIED_SINCE' => last_modified }
    assert Facet::StaticCache.not_modified?(env, nil, last_modified)
  end

  def test_not_modified_false_when_if_modified_since_is_older
    env = { 'HTTP_IF_MODIFIED_SINCE' => Time.at(1_000).utc.httpdate }
    refute Facet::StaticCache.not_modified?(env, nil, Time.at(2_000_000_000).utc.httpdate)
  end

  def test_not_modified_false_when_neither_header_present
    refute Facet::StaticCache.not_modified?({}, '"abc"', 'whatever')
  end

  def test_not_modified_requires_both_conditions_when_both_given
    last_modified = Time.at(1_700_000_000).utc.httpdate
    env = { 'HTTP_IF_NONE_MATCH' => '"abc"', 'HTTP_IF_MODIFIED_SINCE' => Time.at(0).utc.httpdate }
    refute Facet::StaticCache.not_modified?(env, '"abc"', last_modified)
  end

  def test_not_modified_ignores_malformed_if_modified_since
    refute Facet::StaticCache.not_modified?({ 'HTTP_IF_MODIFIED_SINCE' => 'not a date' }, nil, Time.now.utc.httpdate)
  end

  def test_range_applicable_true_when_no_if_range
    assert Facet::StaticCache.range_applicable?({}, 'W/"1-2"', nil)
  end

  def test_range_applicable_true_for_strong_etag_exact_match
    env = { 'HTTP_IF_RANGE' => '"deadbeef"' }
    assert Facet::StaticCache.range_applicable?(env, '"deadbeef"', nil)
  end

  def test_range_applicable_false_when_strong_etag_differs
    env = { 'HTTP_IF_RANGE' => '"deadbeef"' }
    refute Facet::StaticCache.range_applicable?(env, '"cafebabe"', nil)
  end

  def test_range_applicable_false_when_current_etag_is_weak
    env = { 'HTTP_IF_RANGE' => '"1-2"' }
    refute Facet::StaticCache.range_applicable?(env, 'W/"1-2"', nil)
  end

  def test_range_applicable_false_when_client_sends_weak_validator
    env = { 'HTTP_IF_RANGE' => 'W/"deadbeef"' }
    refute Facet::StaticCache.range_applicable?(env, '"deadbeef"', nil)
  end

  def test_range_applicable_true_for_exact_date_match
    last_modified = Time.at(1_700_000_000).utc.httpdate
    env = { 'HTTP_IF_RANGE' => last_modified }
    assert Facet::StaticCache.range_applicable?(env, nil, last_modified)
  end

  def test_range_applicable_false_when_date_is_newer_than_last_modified
    env = { 'HTTP_IF_RANGE' => Time.at(2_000_000_000).utc.httpdate }
    refute Facet::StaticCache.range_applicable?(env, nil, Time.at(1_700_000_000).utc.httpdate)
  end

  def test_range_applicable_false_when_date_is_older_than_last_modified
    env = { 'HTTP_IF_RANGE' => Time.at(1_000).utc.httpdate }
    refute Facet::StaticCache.range_applicable?(env, nil, Time.at(1_700_000_000).utc.httpdate)
  end

  def test_range_applicable_ignores_malformed_if_range_date
    refute Facet::StaticCache.range_applicable?({ 'HTTP_IF_RANGE' => 'garbage' }, nil, Time.now.utc.httpdate)
  end
end
