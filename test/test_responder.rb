require 'minitest/autorun'
require 'prism'

class ResponderTest < Minitest::Test
  def test_dispatches_to_matching_format_block
    responder = Prism::Responder.new
    responder.html { 'html-body' }
    responder.json { 'json-body' }

    assert_equal 'html-body', responder.respond(:html)
    assert_equal 'json-body', responder.respond(:json)
  end

  def test_unknown_format_raises
    responder = Prism::Responder.new
    responder.html { 'html-body' }

    assert_raises(Prism::Responder::UnknownFormat) { responder.respond(:json) }
  end

  def test_any_without_args_is_a_catch_all_fallback
    responder = Prism::Responder.new
    responder.html { 'html-body' }
    responder.any { 'fallback' }

    assert_equal 'html-body', responder.respond(:html)
    assert_equal 'fallback', responder.respond(:json)
    assert_equal 'fallback', responder.respond(:xml)
  end

  def test_any_with_explicit_formats_only_fills_those_in
    responder = Prism::Responder.new
    responder.any(:json, :xml) { 'api-fallback' }

    assert_equal 'api-fallback', responder.respond(:json)
    assert_equal 'api-fallback', responder.respond(:xml)
    assert_raises(Prism::Responder::UnknownFormat) { responder.respond(:html) }
  end

  def test_any_does_not_override_an_explicit_block
    responder = Prism::Responder.new
    responder.json { 'explicit' }
    responder.any { 'fallback' }

    assert_equal 'explicit', responder.respond(:json)
  end

  def test_handles_predicate
    responder = Prism::Responder.new
    responder.html { 'x' }

    assert responder.handles?(:html)
    refute responder.handles?(:json)
  end

  def test_calling_a_format_method_without_a_block_raises
    responder = Prism::Responder.new
    assert_raises(NoMethodError) { responder.frobnicate }
  end
end
