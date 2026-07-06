require 'minitest/autorun'
require 'prism'
require 'stringio'

class InstrumentationTest < Minitest::Test
  def setup
    @bus = Prism::Instrumentation::Bus.new
  end

  def test_instrument_returns_block_value
    result = @bus.instrument('demo.event') { 42 }
    assert_equal 42, result
  end

  def test_subscriber_receives_event_with_name_and_payload
    events = []
    @bus.subscribe('demo.event') { |event| events << event }
    @bus.instrument('demo.event', foo: 'bar') { :ok }

    assert_equal 1, events.size
    assert_equal 'demo.event', events.first.name
    assert_equal 'bar', events.first.payload[:foo]
  end

  def test_duration_is_a_non_negative_float
    events = []
    @bus.subscribe('demo.event') { |event| events << event }
    @bus.instrument('demo.event') { sleep 0.01 }

    assert_kind_of Float, events.first.duration
    assert_operator events.first.duration, :>=, 0.01
    assert_operator events.first.duration_ms, :>=, 10.0
  end

  def test_string_pattern_matches_exact_name_only
    events = []
    @bus.subscribe('demo.event') { |event| events << event }
    @bus.instrument('other.event') { :ok }

    assert_empty events
  end

  def test_regexp_pattern_matches_by_suffix
    events = []
    @bus.subscribe(/\.prism\z/) { |event| events << event }
    @bus.instrument('sql.prism') { :ok }
    @bus.instrument('unrelated.event') { :ok }

    assert_equal ['sql.prism'], events.map(&:name)
  end

  def test_nil_pattern_matches_everything
    events = []
    @bus.subscribe { |event| events << event }
    @bus.instrument('a') { :ok }
    @bus.instrument('b') { :ok }

    assert_equal %w[a b], events.map(&:name)
  end

  def test_multiple_subscribers_all_notified
    calls = []
    @bus.subscribe('demo.event') { calls << :first }
    @bus.subscribe('demo.event') { calls << :second }
    @bus.instrument('demo.event') { :ok }

    assert_equal %i[first second], calls
  end

  def test_unsubscribe_stops_future_notifications
    events = []
    subscriber = @bus.subscribe('demo.event') { |event| events << event }
    @bus.instrument('demo.event') { :ok }
    @bus.unsubscribe(subscriber)
    @bus.instrument('demo.event') { :ok }

    assert_equal 1, events.size
  end

  def test_block_can_mutate_payload_before_publish
    events = []
    @bus.subscribe('demo.event') { |event| events << event }
    @bus.instrument('demo.event', {}) { |payload| payload[:computed] = 'late' }

    assert_equal 'late', events.first.payload[:computed]
  end

  def test_exception_propagates_and_is_recorded_on_payload
    events = []
    @bus.subscribe('demo.event') { |event| events << event }

    assert_raises(RuntimeError) do
      @bus.instrument('demo.event') { raise 'boom' }
    end

    assert_equal 1, events.size, 'event must still publish when the block raises'
    assert_equal ['RuntimeError', 'boom'], events.first.payload[:exception]
    assert_kind_of RuntimeError, events.first.payload[:exception_object]
  end

  def test_instrument_without_block_returns_nil_and_still_publishes
    events = []
    @bus.subscribe('demo.event') { |event| events << event }
    result = @bus.instrument('demo.event')

    assert_nil result
    assert_equal 1, events.size
  end

  def test_concurrent_instrument_and_subscribe_do_not_corrupt_state
    counter = 0
    mutex = Mutex.new
    @bus.subscribe('demo.event') { mutex.synchronize { counter += 1 } }

    threads = Array.new(20) do
      Thread.new { 50.times { @bus.instrument('demo.event') { :ok } } }
    end
    threads.each(&:join)

    assert_equal 1000, counter
  end

  def test_module_level_bus_is_a_singleton
    assert_same Prism::Instrumentation.bus, Prism::Instrumentation.bus
  end

  def test_module_level_instrument_and_subscribe_delegate_to_bus
    events = []
    subscriber = Prism::Instrumentation.subscribe('module.demo') { |event| events << event }
    Prism::Instrumentation.instrument('module.demo') { :ok }
    Prism::Instrumentation.unsubscribe(subscriber)

    assert_equal 1, events.size
  end
end

class InstrumentationLogSubscriberTest < Minitest::Test
  def setup
    @bus = Prism::Instrumentation::Bus.new
    @io = StringIO.new
  end

  def test_attach_writes_one_formatted_line_per_event
    subscribers = attach_to(@bus, @io, patterns: ['sql.prism'])
    @bus.instrument('sql.prism', operation: 'SELECT', table: 'posts') { :ok }
    subscribers.each { |s| @bus.unsubscribe(s) }

    line = @io.string.lines.first
    assert_match(/sql\.prism \(\d+\.\d ms\)/, line.gsub('ms)', ' ms)'))
    assert_match(/operation="SELECT"/, line)
    assert_match(/table="posts"/, line)
  end

  def test_attach_ignores_events_not_matching_pattern
    attach_to(@bus, @io, patterns: ['sql.prism'])
    @bus.instrument('render_template.prism', identifier: 'posts/index') { :ok }

    assert_empty @io.string
  end

  def test_attach_hides_exception_object_from_output
    attach_to(@bus, @io, patterns: ['demo.event'])
    assert_raises(RuntimeError) { @bus.instrument('demo.event') { raise 'boom' } }

    refute_match(/exception_object/, @io.string)
    assert_match(/exception=\["RuntimeError", "boom"\]/, @io.string)
  end

  def test_attach_wires_to_the_process_wide_bus
    subscribers = Prism::Instrumentation::LogSubscriber.attach(@io, patterns: ['demo.singleton'])
    Prism::Instrumentation.instrument('demo.singleton', a: 1) { :ok }
    subscribers.each { |s| Prism::Instrumentation.unsubscribe(s) }
    Prism::Instrumentation.instrument('demo.singleton', a: 2) { :ok }

    assert_equal 1, @io.string.lines.size
    assert_match(/a=1/, @io.string)
  end

  private

  # Most assertions here only need LogSubscriber's formatting, so they run
  # against a throwaway Bus instead of the process-wide singleton to stay
  # isolated from other tests; #attach itself is exercised separately above.
  def attach_to(bus, io, patterns:)
    patterns.map { |pattern| bus.subscribe(pattern) { |event| io.puts(Prism::Instrumentation::LogSubscriber.format_event(event)) } }
  end
end
