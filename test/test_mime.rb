require 'minitest/autorun'
require 'facet'

class MimeTest < Minitest::Test
  def test_lookup_by_symbol
    assert_equal 'application/json', Facet::Mime[:json]
    assert_equal 'text/html', Facet::Mime[:html]
  end

  def test_unknown_symbol_raises
    assert_raises(Facet::Mime::UnknownMimeType) { Facet::Mime[:yaml] }
  end

  def test_known_predicate
    assert Facet::Mime.known?(:json)
    refute Facet::Mime.known?(:yaml)
  end

  def test_symbol_for_content_type_strips_charset
    assert_equal :json, Facet::Mime.symbol_for_content_type('application/json; charset=utf-8')
    assert_equal :html, Facet::Mime.symbol_for_content_type('text/html')
    assert_nil Facet::Mime.symbol_for_content_type('application/octet-stream')
    assert_nil Facet::Mime.symbol_for_content_type(nil)
  end

  def test_best_from_accept_picks_highest_q
    header = 'text/html;q=0.5, application/json;q=0.9, application/xml;q=0.1'
    assert_equal :json, Facet::Mime.best_from_accept(header)
  end

  def test_best_from_accept_defaults_q_to_one
    header = 'application/xml;q=0.5, text/html'
    assert_equal :html, Facet::Mime.best_from_accept(header)
  end

  def test_best_from_accept_preserves_order_on_tie
    header = 'application/xml, application/json'
    assert_equal :xml, Facet::Mime.best_from_accept(header)
  end

  def test_best_from_accept_wildcard_defaults_to_html
    assert_equal :html, Facet::Mime.best_from_accept('*/*')
  end

  def test_best_from_accept_returns_nil_for_unknown_types_only
    assert_nil Facet::Mime.best_from_accept('application/octet-stream')
  end

  def test_best_from_accept_returns_nil_for_blank_header
    assert_nil Facet::Mime.best_from_accept(nil)
    assert_nil Facet::Mime.best_from_accept('')
  end
end
