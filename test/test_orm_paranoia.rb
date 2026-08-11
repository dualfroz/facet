require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'fileutils'

class OrmParanoiaTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-paranoia-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:widgets, %w[id name deleted_at])
    @store.create_table(:plain_things, %w[id name])
    @store.create_table(:locked_widgets, %w[id name deleted_at lock_version])
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id deleted_at])
    @store.create_table(:blogs, %w[id name deleted_at entries_count])
    @store.create_table(:entries, %w[id title blog_id deleted_at])

    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      acts_as_paranoid
    end
    plain_class = Class.new(Prism::Orm::Model) { table_name :plain_things }
    locked_widget_class = Class.new(Prism::Orm::Model) do
      table_name :locked_widgets
      acts_as_paranoid
    end
    author_class = Class.new(Prism::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id', dependent: :destroy
    end
    post_class = Class.new(Prism::Orm::Model) do
      table_name :posts
      acts_as_paranoid
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end

    blog_class = Class.new(Prism::Orm::Model) do
      table_name :blogs
      acts_as_paranoid
      has_many :entries, class_name: 'Entry', foreign_key: 'blog_id', dependent: :destroy
    end
    entry_class = Class.new(Prism::Orm::Model) do
      table_name :entries
      acts_as_paranoid
      belongs_to :blog, class_name: 'Blog', foreign_key: 'blog_id', counter_cache: true
    end

    [widget_class, plain_class, locked_widget_class, author_class, post_class, blog_class, entry_class].each do |klass|
      klass.store = @store
    end
    Object.const_set(:Widget, widget_class)
    Object.const_set(:PlainThing, plain_class)
    Object.const_set(:LockedWidget, locked_widget_class)
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
    Object.const_set(:Blog, blog_class)
    Object.const_set(:Entry, entry_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Widget PlainThing LockedWidget Author Post Blog Entry].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end

  def test_plain_model_is_not_paranoid_and_destroy_removes_the_row_for_real
    refute PlainThing.paranoid?
    thing = PlainThing.create!(name: 'gizmo')
    thing.destroy
    assert_raises(Prism::Orm::RecordNotFound) { PlainThing.find(thing.id) }
  end

  def test_paranoid_destroy_stamps_the_column_instead_of_deleting
    widget = Widget.create!(name: 'gizmo')
    widget.destroy

    assert widget.destroyed?
    row = @store.find('widgets', widget.id)
    refute_nil row, 'the row must still physically exist'
    refute_nil row['deleted_at']
  end

  def test_paranoid_destroy_hides_the_record_from_find_all_and_count
    widget = Widget.create!(name: 'gizmo')
    widget.destroy

    assert_raises(Prism::Orm::RecordNotFound) { Widget.find(widget.id) }
    assert_empty Widget.all.to_a
    assert_equal 0, Widget.count
  end

  def test_paranoid_destroy_still_runs_before_and_after_destroy_callbacks
    log = []
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      acts_as_paranoid
      before_destroy { log << :before_destroy }
      after_destroy { log << :after_destroy }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')

    widget.destroy

    assert_equal %i[before_destroy after_destroy], log
  end

  def test_before_destroy_abort_leaves_the_record_undeleted
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      acts_as_paranoid
      before_destroy { throw :abort }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')

    widget.destroy

    refute widget.destroyed?
    assert widget_class.find(widget.id)
  end

  def test_deleted_predicate
    widget = Widget.create!(name: 'gizmo')
    refute widget.deleted?
    widget.destroy
    assert widget.deleted?
  end

  def test_soft_deleting_predicate_is_true_inside_before_destroy_for_a_plain_soft_delete
    seen = nil
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      acts_as_paranoid
      before_destroy { seen = soft_deleting? }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')

    widget.destroy

    assert_equal true, seen
    assert widget.soft_deleting?, 'still true after #destroy returns, not just mid-callback'
  end

  def test_soft_deleting_predicate_is_false_for_really_destroy_bang
    seen = nil
    widget_class = Class.new(Prism::Orm::Model) do
      table_name :widgets
      acts_as_paranoid
      before_destroy { seen = soft_deleting? }
    end
    widget_class.store = @store
    widget = widget_class.create!(name: 'gizmo')

    widget.really_destroy!

    assert_equal false, seen
  end

  def test_soft_deleting_predicate_is_false_for_a_non_paranoid_model
    seen = nil
    plain_class = Class.new(Prism::Orm::Model) do
      table_name :plain_things
      before_destroy { seen = soft_deleting? }
    end
    plain_class.store = @store
    thing = plain_class.create!(name: 'gizmo')

    thing.destroy

    assert_equal false, seen
  end

  def test_restore_undoes_a_soft_delete
    widget = Widget.create!(name: 'gizmo')
    widget.destroy
    refute_includes Widget.all.map(&:id), widget.id

    widget.restore

    refute widget.destroyed?
    refute widget.deleted?
    assert_includes Widget.all.map(&:id), widget.id
    assert_nil Widget.find(widget.id).deleted_at
  end

  def test_restore_on_a_record_that_was_never_deleted_is_a_no_op
    widget = Widget.create!(name: 'gizmo')
    widget.restore
    refute widget.deleted?
  end

  def test_with_deleted_sees_both_live_and_soft_deleted_records
    live = Widget.create!(name: 'live')
    dead = Widget.create!(name: 'dead')
    dead.destroy

    ids = Widget.with_deleted.map(&:id)
    assert_includes ids, live.id
    assert_includes ids, dead.id
    assert_equal [dead.id], Widget.only_deleted.map(&:id)
  end

  def test_really_destroy_bang_removes_the_row_for_real
    widget = Widget.create!(name: 'gizmo')
    widget.destroy
    assert_includes Widget.only_deleted.map(&:id), widget.id

    widget.really_destroy!

    assert_nil @store.find('widgets', widget.id)
    refute_includes Widget.with_deleted.map(&:id), widget.id
  end

  def test_really_destroy_bang_on_a_non_paranoid_model_behaves_like_plain_destroy
    thing = PlainThing.create!(name: 'gizmo')
    thing.really_destroy!
    assert_raises(Prism::Orm::RecordNotFound) { PlainThing.find(thing.id) }
  end

  def test_dependent_destroy_cascades_a_soft_delete_to_paranoid_children
    author = Author.create!(name: 'foksiu')
    post = Post.create!(title: 'hello', author_id: author.id)

    author.destroy

    refute_nil @store.find('posts', post.id), 'child row must still physically exist'
    assert_empty Post.all.to_a
    assert_includes Post.only_deleted.map(&:id), post.id
  end

  def test_paranoid_destroy_still_respects_optimistic_locking
    original = LockedWidget.create!(name: 'a')
    stale_copy = LockedWidget.find(original.id)
    original.update!(name: 'changed')

    error = assert_raises(Prism::Orm::StaleObjectError) { stale_copy.destroy }
    assert_equal :destroy, error.attempted_action
    refute stale_copy.destroyed?
    refute_nil LockedWidget.find(original.id), 'stale soft-delete must not have stamped the row'
  end

  def test_paranoid_column_can_be_customized
    @store.create_table(:archivables, %w[id name archived_at])
    archivable_class = Class.new(Prism::Orm::Model) do
      table_name :archivables
      acts_as_paranoid column: 'archived_at'
    end
    archivable_class.store = @store

    record = archivable_class.create!(name: 'a')
    record.destroy

    assert_equal 'archived_at', archivable_class.paranoid_column
    assert_empty archivable_class.all.to_a
    refute_nil @store.find('archivables', record.id)['archived_at']
  end

  def test_paranoid_setting_is_inherited_by_subclasses
    subclass = Class.new(Widget) { table_name :widgets }
    subclass.store = @store

    assert subclass.paranoid?
    assert_equal 'deleted_at', subclass.paranoid_column

    record = subclass.create!(name: 'a')
    record.destroy
    assert_empty subclass.all.to_a
  end

  def test_plain_restore_does_not_bring_back_dependent_destroyed_children
    blog = Blog.create!(name: 'main', entries_count: 0)
    entry = Entry.create!(title: 'first', blog_id: blog.id)
    blog.destroy
    assert_includes Entry.only_deleted.map(&:id), entry.id

    blog.restore

    refute blog.deleted?
    assert_includes Entry.only_deleted.map(&:id), entry.id, 'a non-recursive restore must leave children trashed'
  end

  def test_recursive_restore_brings_back_paranoid_dependent_children
    blog = Blog.create!(name: 'main', entries_count: 0)
    e1 = Entry.create!(title: 'first', blog_id: blog.id)
    e2 = Entry.create!(title: 'second', blog_id: blog.id)
    blog.destroy
    assert_empty Entry.all.to_a

    blog.restore(recursive: true)

    ids = Entry.all.map(&:id)
    assert_includes ids, e1.id
    assert_includes ids, e2.id
    assert_equal 2, blog.reload.entries_count, 'counter_cache must be restored along with each child'
  end

  def test_recursive_restore_recurses_into_grandchildren
    @store.create_table(:pages, %w[id title entry_id deleted_at])
    page_class = Class.new(Prism::Orm::Model) do
      table_name :pages
      acts_as_paranoid
      belongs_to :entry, class_name: 'Entry', foreign_key: 'entry_id'
    end
    page_class.store = @store
    Object.const_set(:Page, page_class)
    Entry.has_many :pages, class_name: 'Page', foreign_key: 'entry_id', dependent: :destroy

    blog = Blog.create!(name: 'main', entries_count: 0)
    entry = Entry.create!(title: 'first', blog_id: blog.id)
    page = Page.create!(title: 'sub', entry_id: entry.id)
    blog.destroy
    assert_includes Page.only_deleted.map(&:id), page.id

    blog.restore(recursive: true)

    assert_includes Page.all.map(&:id), page.id
  ensure
    Object.send(:remove_const, :Page) if Object.const_defined?(:Page)
  end

  def test_restore_runs_before_and_after_restore_callbacks_in_order
    calls = []
    Widget.before_restore { calls << :before }
    Widget.after_restore { calls << :after }
    widget = Widget.create!(name: 'gizmo')
    widget.destroy

    widget.restore

    assert_equal %i[before after], calls
  end

  def test_before_restore_abort_leaves_the_record_soft_deleted
    Widget.before_restore { throw :abort }
    widget = Widget.create!(name: 'gizmo')
    widget.destroy

    widget.restore

    assert widget.deleted?
    assert_includes Widget.only_deleted.map(&:id), widget.id
  end
end
