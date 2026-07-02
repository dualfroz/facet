require 'minitest/autorun'
require 'prism'
require 'support'

class StreamingExportController < Prism::Controller
  after_action :log_after

  def self.after_log
    @after_log ||= []
  end

  def export
    headers('Content-Type' => 'text/csv')
    stream do |out|
      out.write("id,title\n")
      %w[one two three].each_with_index do |title, index|
        out.write("#{index + 1},#{title}\n")
      end
    end
  end

  def plain
    json(ok: true)
  end

  private

  def log_after
    self.class.after_log << action_name
  end
end

class StreamingApp < Prism::Application
  get '/export', to: 'streaming_export#export'
  get '/plain', to: 'streaming_export#plain'
end

class ControllerStreamingTest < Minitest::Test
  include TestSupport

  def setup
    StreamingExportController.after_log.clear
  end

  def call(env)
    StreamingApp.call(env)
  end

  def test_streaming_action_returns_a_streaming_body
    _status, _headers, body = call(env_for(:get, '/export'))
    assert_instance_of Prism::StreamingBody, body
  end

  def test_streaming_action_produces_chunks_in_order_when_drained
    _status, _headers, body = call(env_for(:get, '/export'))
    collected = []
    body.each { |chunk| collected << chunk }
    assert_equal ["id,title\n", "1,one\n", "2,two\n", "3,three\n"], collected
  end

  def test_streaming_action_keeps_status_and_explicit_headers
    status, headers, _body = call(env_for(:get, '/export'))
    assert_equal 200, status
    assert_equal 'text/csv', headers['Content-Type']
  end

  # Regression guard: finalize_body used to call `@response.body.empty?`
  # unconditionally after every action, which raises NoMethodError against
  # a StreamingBody (it deliberately has no #empty?, since a producer
  # block's total chunk count is not known up front).
  def test_after_actions_still_run_for_a_streaming_action
    call(env_for(:get, '/export'))
    assert_equal ['export'], StreamingExportController.after_log
  end

  # Non-streaming actions on the same controller are unaffected by the
  # streaming? guard added to finalize_body.
  def test_ordinary_action_on_the_same_controller_is_unaffected
    status, _headers, body = call(env_for(:get, '/plain'))
    assert_equal 200, status
    assert_equal ['{"ok":true}'], body
  end
end
