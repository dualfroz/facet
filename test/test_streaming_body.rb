require 'minitest/autorun'
require 'facet'

class StreamingBodyTest < Minitest::Test
  def test_each_yields_chunks_in_write_order
    body = Facet::StreamingBody.new do |out|
      out.write('a')
      out.write('b')
      out << 'c'
    end

    collected = []
    body.each { |chunk| collected << chunk }
    assert_equal %w[a b c], collected
  end

  def test_write_coerces_non_string_chunks_to_string
    body = Facet::StreamingBody.new { |out| out.write(42) }

    collected = []
    body.each { |chunk| collected << chunk }
    assert_equal ['42'], collected
    assert collected.first.is_a?(String)
  end

  def test_producer_block_does_not_run_until_each_is_called
    ran = false
    body = Facet::StreamingBody.new { ran = true }
    refute ran
    body.each { |_chunk| nil }
    assert ran
  end

  def test_each_can_be_called_more_than_once_and_reruns_the_producer
    calls = 0
    body = Facet::StreamingBody.new do |out|
      calls += 1
      out.write("call-#{calls}")
    end

    first = []
    body.each { |chunk| first << chunk }
    second = []
    body.each { |chunk| second << chunk }

    assert_equal ['call-1'], first
    assert_equal ['call-2'], second
  end
end
