require 'minitest/autorun'
require 'prism'
require 'support'

class FilterController < Prism::Controller
  before_action(only: %i[index]) { @log = (@log || []) << 'inline-before' }
  before_action :require_token, except: %i[public_action]
  after_action :log_after, except: %i[public_action]

  def self.after_log
    @after_log ||= []
  end

  def index
    json(log: @log)
  end

  def secret
    json(reached: true)
  end

  def public_action
    json(reached: true)
  end

  private

  def require_token
    halt(401, 'no token') unless params['token'] == 'ok'
  end

  def log_after
    self.class.after_log << action_name
  end
end

class FilterApp < Prism::Application
  get '/index', to: 'filter#index'
  get '/secret', to: 'filter#secret'
  get '/public', to: 'filter#public_action'
end

class ControllerFiltersTest < Minitest::Test
  include TestSupport

  def setup
    FilterController.after_log.clear
  end

  def call(method, path, **opts)
    FilterApp.call(env_for(method, path, **opts))
  end

  def test_inline_before_action_block_runs_and_scoped_to_only
    _, _, body = call('GET', '/index?token=ok')
    assert_equal ['inline-before'], JSON.parse(body.join)['log']
  end

  def test_before_action_with_except_still_guards_other_actions
    status, _, body = call('GET', '/secret')
    assert_equal 401, status
    assert_equal 'no token', body.join
  end

  def test_before_action_except_skips_the_named_action
    status, _, body = call('GET', '/public')
    assert_equal 200, status
    assert JSON.parse(body.join)['reached']
  end

  def test_halted_before_action_prevents_the_action_body_from_running
    status, _, body = call('GET', '/secret')
    refute_equal 200, status
    refute_includes body.join, 'reached'
  end

  def test_after_action_runs_when_before_action_passes
    call('GET', '/secret?token=ok')
    assert_includes FilterController.after_log, 'secret'
  end

  def test_after_action_except_is_honored
    call('GET', '/public')
    refute_includes FilterController.after_log, 'public_action'
  end
end
