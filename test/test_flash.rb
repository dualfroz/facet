require 'minitest/autorun'
require 'prism'

class FlashTest < Minitest::Test
  def test_set_value_is_not_visible_in_same_flash_read_before_sweep
    session = Prism::Params.new
    flash = Prism::Flash.new(session)
    flash[:notice] = 'saved'
    assert_nil flash[:notice], 'value set this request should not be readable via [] until next request'
  end

  def test_sweep_persists_pending_values_into_session
    session = Prism::Params.new
    flash = Prism::Flash.new(session)
    flash[:notice] = 'saved'
    flash.sweep
    assert_equal({ 'notice' => 'saved' }, session['_flash'])
  end

  def test_next_request_reads_previous_pending_value
    session = Prism::Params.new
    first = Prism::Flash.new(session)
    first[:notice] = 'saved'
    first.sweep

    second = Prism::Flash.new(session)
    assert_equal 'saved', second[:notice]
  end

  def test_flash_does_not_carry_over_a_second_time
    session = Prism::Params.new
    first = Prism::Flash.new(session)
    first[:notice] = 'saved'
    first.sweep

    second = Prism::Flash.new(session)
    second[:notice]
    second.sweep

    third = Prism::Flash.new(session)
    assert_nil third[:notice]
  end

  def test_now_reads_current_flash_without_waiting_for_sweep
    session = Prism::Params.new
    session['_flash'] = { 'notice' => 'saved' }
    flash = Prism::Flash.new(session)
    assert_equal 'saved', flash.now[:notice]
  end

  def test_keep_carries_current_flash_into_next_request
    session = Prism::Params.new
    session['_flash'] = { 'notice' => 'saved' }
    flash = Prism::Flash.new(session)
    flash.keep
    flash.sweep

    next_flash = Prism::Flash.new(session)
    assert_equal 'saved', next_flash[:notice]
  end

  def test_empty_predicate
    session = Prism::Params.new
    flash = Prism::Flash.new(session)
    assert flash.empty?
    session['_flash'] = { 'notice' => 'x' }
    assert Prism::Flash.new(session).empty? == false
  end
end
