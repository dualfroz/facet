require 'minitest/autorun'
require 'facet'
require 'support'

class RescueFromMissingRecordError < StandardError; end
class RescueFromSpecificError < RescueFromMissingRecordError; end

class RescueFromBaseController < Facet::Controller
  rescue_from StandardError, with: :handle_any_error

  private

  def handle_any_error(exception)
    halt(500, "base handled #{exception.class}")
  end
end

class RescueFromController < RescueFromBaseController
  rescue_from RescueFromMissingRecordError, with: :handle_missing_record
  rescue_from ArgumentError do |exception|
    halt(400, "block handled #{exception.message}")
  end

  def boom_missing
    raise RescueFromMissingRecordError, 'gone'
  end

  def boom_specific_subclass
    raise RescueFromSpecificError, 'gone'
  end

  def boom_argument
    raise ArgumentError, 'bad input'
  end

  def boom_unhandled
    raise ZeroDivisionError, 'nope'
  end

  def before_action_boom
    raise RescueFromMissingRecordError, 'blocked before the action ran'
  end

  before_action :before_action_boom, only: %i[protected_action]

  def protected_action
    halt(200, 'should never reach here')
  end

  private

  def handle_missing_record(exception)
    halt(404, "missing #{exception.message}")
  end
end

class RescueFromApp < Facet::Application
  get '/missing', to: 'rescue_from#boom_missing'
  get '/missing_subclass', to: 'rescue_from#boom_specific_subclass'
  get '/argument', to: 'rescue_from#boom_argument'
  get '/unhandled', to: 'rescue_from#boom_unhandled'
  get '/protected', to: 'rescue_from#protected_action'
end

class ControllerRescueFromTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    RescueFromApp.call(env_for(method, path, **opts))
  end

  def test_specific_handler_declared_on_the_subclass_wins_over_the_superclass_catch_all
    status, _, body = call('GET', '/missing')
    assert_equal 404, status
    assert_equal 'missing gone', body.join
  end

  def test_is_a_matching_catches_a_subclass_of_the_registered_exception
    status, _, body = call('GET', '/missing_subclass')
    assert_equal 404, status
    assert_equal 'missing gone', body.join
  end

  def test_block_handler_runs_with_the_controller_as_self
    status, _, body = call('GET', '/argument')
    assert_equal 400, status
    assert_equal 'block handled bad input', body.join
  end

  def test_falls_back_to_the_superclass_catch_all_when_no_specific_handler_matches
    status, _, body = call('GET', '/unhandled')
    assert_equal 500, status
    assert_equal 'base handled ZeroDivisionError', body.join
  end

  def test_rescue_from_also_catches_exceptions_raised_inside_before_actions
    status, _, body = call('GET', '/protected')
    assert_equal 404, status
    assert_equal 'missing blocked before the action ran', body.join
  end
end
