require 'minitest/autorun'
require 'prism'
require 'support'

class ErrorHandlingBoomController < Prism::Controller
  def index
    raise 'kaboom, no rescue_from anywhere for this one'
  end
end

class ErrorHandlingFineController < Prism::Controller
  def index
    halt(200, 'fine')
  end
end

class ErrorHandlingApp < Prism::Application
  get '/boom', to: 'error_handling_boom#index'
  get '/fine', to: 'error_handling_fine#index'
end

class ApplicationErrorHandlingTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    ErrorHandlingApp.call(env_for(method, path, **opts))
  end

  def test_unhandled_exception_becomes_a_safe_500_instead_of_crashing_the_request
    status, headers, body = call('GET', '/boom')
    assert_equal 500, status
    assert_equal 'text/plain', headers['Content-Type']
    assert_equal 'Internal Server Error', body.join
  end

  def test_the_500_body_never_leaks_the_exception_message
    _, _, body = call('GET', '/boom')
    refute_includes body.join, 'kaboom'
  end

  def test_unrelated_requests_are_unaffected_by_the_fallback
    status, _, body = call('GET', '/fine')
    assert_equal 200, status
    assert_equal 'fine', body.join
  end

  def test_the_exception_is_still_recorded_on_the_instrumentation_payload
    events = []
    subscriber = Prism::Instrumentation.subscribe('process_action.prism') { |event| events << event }
    call('GET', '/boom')
    klass, message = events.last.payload[:exception]
    assert_equal 'RuntimeError', klass
    assert_includes message, 'kaboom'
  ensure
    Prism::Instrumentation.unsubscribe(subscriber)
  end
end
