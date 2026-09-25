require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class HttpRangeTest < Minitest::Test
  def test_no_header_returns_nil
    assert_nil Facet::HttpRange.parse(nil, 100)
  end

  def test_non_bytes_unit_is_ignored
    assert_nil Facet::HttpRange.parse('items=0-1', 100)
  end

  def test_multi_range_is_ignored_not_unsatisfiable
    assert_nil Facet::HttpRange.parse('bytes=0-10,20-30', 100)
  end

  def test_simple_start_end
    result = Facet::HttpRange.parse('bytes=0-9', 100)
    assert_equal 0, result.start
    assert_equal 9, result.finish
    assert_equal 10, result.length
  end

  def test_open_ended_range_clamps_to_file_size
    result = Facet::HttpRange.parse('bytes=90-', 100)
    assert_equal 90, result.start
    assert_equal 99, result.finish
    assert_equal 10, result.length
  end

  def test_end_beyond_file_size_is_clamped_not_rejected
    result = Facet::HttpRange.parse('bytes=0-999', 100)
    assert_equal 99, result.finish
  end

  def test_suffix_range_returns_last_n_bytes
    result = Facet::HttpRange.parse('bytes=-10', 100)
    assert_equal 90, result.start
    assert_equal 99, result.finish
    assert_equal 10, result.length
  end

  def test_suffix_range_larger_than_file_clamps_to_whole_file
    result = Facet::HttpRange.parse('bytes=-1000', 100)
    assert_equal 0, result.start
    assert_equal 99, result.finish
  end

  def test_start_beyond_file_size_is_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=100-200', 100)
  end

  def test_start_after_end_is_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=50-10', 100)
  end

  def test_empty_start_and_end_is_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=-', 100)
  end

  def test_garbage_spec_is_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=abc-def', 100)
  end

  def test_zero_length_suffix_is_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=-0', 100)
  end

  def test_empty_file_is_always_unsatisfiable
    assert_equal :unsatisfiable, Facet::HttpRange.parse('bytes=0-0', 0)
  end

  def test_read_slice_returns_only_the_requested_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'data.bin')
      File.binwrite(path, '0123456789')
      slice = Facet::HttpRange.parse('bytes=2-5', 10)
      assert_equal '2345', Facet::HttpRange.read_slice(path, slice)
    end
  end
end
