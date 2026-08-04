require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class OrmLockingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-locking')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name lock_version])
    @store.create_table(:plain_things, %w[id name])

    widget_class = Class.new(Prism::Orm::Model) { table_name :widgets }
    plain_class = Class.new(Prism::Orm::Model) { table_name :plain_things }
    [widget_class, plain_class].each { |klass| klass.store = @store }
    Object.const_set(:Widget, widget_class)
    Object.const_set(:PlainThing, plain_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Widget PlainThing].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_locking_enabled_when_lock_version_column_present
    assert Widget.locking_enabled?
    refute PlainThing.locking_enabled?
  end

  def test_create_initializes_lock_version_to_zero
    widget = Widget.create!(name: 'a')
    assert_equal 0, widget.lock_version
  end

  def test_create_does_not_overwrite_an_explicitly_assigned_lock_version
    widget = Widget.create!(name: 'a', lock_version: 5)
    assert_equal 5, widget.lock_version
  end

  def test_update_increments_lock_version
    widget = Widget.create!(name: 'a')
    widget.update!(name: 'b')
    assert_equal 1, widget.lock_version
    widget.update!(name: 'c')
    assert_equal 2, widget.lock_version
    assert_equal 2, Widget.find(widget.id).lock_version
  end

  def test_stale_update_raises_stale_object_error
    original = Widget.create!(name: 'a')
    stale_copy = Widget.find(original.id)

    original.update!(name: 'fresh')

    stale_copy.name = 'stale'
    error = assert_raises(Prism::Orm::StaleObjectError) { stale_copy.save! }
    assert_same stale_copy, error.record
    assert_equal :update, error.attempted_action

    reloaded = Widget.find(original.id)
    assert_equal 'fresh', reloaded.name, 'the stale write must not have overwritten the fresh row'
  end

  def test_reloading_after_a_stale_error_allows_a_later_save_to_succeed
    original = Widget.create!(name: 'a')
    stale_copy = Widget.find(original.id)
    original.update!(name: 'fresh')

    stale_copy.name = 'stale'
    assert_raises(Prism::Orm::StaleObjectError) { stale_copy.save! }

    stale_copy.reload
    stale_copy.name = 'retried'
    assert stale_copy.save!
    assert_equal 'retried', Widget.find(original.id).name
  end

  def test_stale_destroy_raises_stale_object_error
    original = Widget.create!(name: 'a')
    stale_copy = Widget.find(original.id)
    original.update!(name: 'changed')

    error = assert_raises(Prism::Orm::StaleObjectError) { stale_copy.destroy }
    assert_equal :destroy, error.attempted_action
    refute_nil Widget.find(original.id), 'stale destroy must not have deleted the row'
  end

  def test_current_destroy_succeeds
    widget = Widget.create!(name: 'a')
    widget.destroy
    assert_raises(Prism::Orm::RecordNotFound) { Widget.find(widget.id) }
  end

  def test_model_without_lock_version_column_ignores_locking_entirely
    thing = PlainThing.create!(name: 'a')
    stale = PlainThing.find(thing.id)
    thing.update!(name: 'first writer')
    stale.update!(name: 'second writer wins, no locking')
    assert_equal 'second writer wins, no locking', PlainThing.find(thing.id).name
  end

  def test_locking_column_can_be_customized
    @store.create_table(:gizmos, %w[id name version_number])
    gizmo_class = Class.new(Prism::Orm::Model) do
      table_name :gizmos
      locking_column :version_number
    end
    gizmo_class.store = @store

    gizmo = gizmo_class.create!(name: 'a')
    assert_equal 0, gizmo.version_number
    gizmo.update!(name: 'b')
    assert_equal 1, gizmo.version_number

    stale = gizmo_class.find(gizmo.id)
    gizmo.update!(name: 'c')
    stale.name = 'stale'
    assert_raises(Prism::Orm::StaleObjectError) { stale.save! }
  end

  # Real cross-process proof: N processes each retry a load -> increment ->
  # save loop against the SAME row until their own increment sticks. If the
  # version check and the write were not inside the same PStore transaction
  # (or if Model silently swallowed StaleObjectError instead of raising),
  # concurrent writers would stomp on each other's increments and the final
  # counter would fall short of the true total - the classic optimistic
  # locking lost-update problem this feature exists to prevent.
  def test_prevents_lost_updates_across_real_concurrent_processes
    store_path = File.join(@dir, 'shared.pstore')
    shared_store = Prism::Orm::Store.new(store_path)
    shared_store.create_table(:counters, %w[id counter lock_version])
    shared_store.insert(:counters, id: 1, counter: 0, lock_version: 0)

    process_count = 4
    increments_per_process = 20

    racer_script = File.join(@dir, 'racer.rb')
    File.write(racer_script, <<~RUBY)
      require 'prism'
      store = Prism::Orm::Store.new(#{store_path.inspect})
      Counter = Class.new(Prism::Orm::Model) { table_name :counters }
      Counter.store = store

      successes = 0
      retries = 0
      while successes < #{increments_per_process}
        counter = Counter.find(1)
        counter.counter = counter.counter + 1
        sleep(rand * 0.005) # widen the read-then-write window so processes actually overlap
        begin
          counter.save!
          successes += 1
        rescue Prism::Orm::StaleObjectError
          retries += 1
        end
      end
      File.write(File.join(#{@dir.inspect}, "\#{Process.pid}.retries"), retries.to_s)
    RUBY

    pids = process_count.times.map do
      Process.spawn(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), racer_script,
                     out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.waitpid(pid) }

    expected_total = process_count * increments_per_process
    final = shared_store.find(:counters, 1)
    assert_equal expected_total, final['counter'],
                 'every successful save must have applied its own +1 - a lost update means ' \
                 'this falls short of the true total'
    assert_equal expected_total, final['lock_version']

    total_retries = pids.sum { |pid| Integer(File.read(File.join(@dir, "#{pid}.retries"))) }
    assert total_retries.positive?,
           'with 4 processes racing on one row, at least one save should have collided and ' \
           'had to retry - a suspiciously zero count would suggest the processes never ' \
           'actually overlapped'
  end
end
