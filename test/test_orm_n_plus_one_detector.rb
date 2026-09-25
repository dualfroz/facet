require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'stringio'

class OrmNPlusOneDetectorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-n-plus-one-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name])
    @store.create_table(:posts, %w[id title author_id])
    @store.create_table(:bios, %w[id author_id headline])

    author_class = Class.new(Facet::Orm::Model) do
      table_name :authors
      has_many :posts, class_name: 'Post', foreign_key: 'author_id'
      has_one :bio, class_name: 'Bio', foreign_key: 'author_id'
    end
    post_class = Class.new(Facet::Orm::Model) do
      table_name :posts
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    bio_class = Class.new(Facet::Orm::Model) do
      table_name :bios
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    [author_class, post_class, bio_class].each { |klass| klass.store = @store }
    Object.const_set(:Author, author_class)
    Object.const_set(:Post, post_class)
    Object.const_set(:Bio, bio_class)

    @io = StringIO.new
  end

  def teardown
    Facet::Orm::NPlusOneDetector.disable!
    Facet::Orm::NPlusOneDetector.reset!
    FileUtils.remove_entry(@dir)
    %i[Author Post Bio].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def create_authors_with_posts(count)
    count.times do |i|
      author = Author.create!(name: "author#{i}")
      Post.create!(title: "post#{i}", author_id: author.id)
      author
    end
  end

  def test_disabled_by_default_never_warns_even_on_an_obvious_n_plus_one
    create_authors_with_posts(5)
    Author.all.to_a.each { |author| author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!
    assert_empty @io.string
  end

  def test_below_threshold_does_not_warn
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(1)

    Author.all.to_a.each { |author| author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!

    assert_empty @io.string
  end

  def test_reaching_threshold_across_distinct_owners_warns
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(3)

    Author.all.to_a.each { |author| author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!

    assert_match(/N\+1 query detected: Author#posts lazily loaded for 3 separate Author records/, @io.string)
    assert_match(/\.includes\(:posts\)/, @io.string)
  end

  def test_preloaded_via_includes_never_counts_as_a_lazy_load
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(3)

    Author.all.includes(:posts).to_a.each { |author| author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!

    assert_empty @io.string
  end

  def test_repeated_reads_on_the_same_owner_do_not_inflate_the_count
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(1)
    author = Author.first

    5.times { author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!

    assert_empty @io.string, 'one owner read five times is still one owner, not five'
  end

  def test_two_different_associations_are_tracked_and_reported_independently
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    3.times do |i|
      author = Author.create!(name: "author#{i}")
      Post.create!(title: "post#{i}", author_id: author.id)
      Bio.create!(headline: "bio#{i}", author_id: author.id)
    end

    Author.all.to_a.each do |author|
      author.posts.to_a
      author.bio
    end
    Facet::Orm::NPlusOneDetector.report!

    assert_match(/Author#posts lazily loaded for 3/, @io.string)
    assert_match(/Author#bio lazily loaded for 3/, @io.string)
  end

  def test_belongs_to_lazy_loads_across_distinct_children_are_detected_too
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    author = Author.create!(name: 'shared')
    3.times { |i| Post.create!(title: "post#{i}", author_id: author.id) }

    Post.all.to_a.each(&:author)
    Facet::Orm::NPlusOneDetector.report!

    assert_match(/Post#author lazily loaded for 3 separate Post records/, @io.string)
  end

  def test_raise_on_violation_raises_instead_of_only_logging
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io, raise_on_violation: true)
    create_authors_with_posts(2)

    error = assert_raises(Facet::Orm::NPlusOneViolation) do
      Author.all.to_a.each { |author| author.posts.to_a }
      Facet::Orm::NPlusOneDetector.report!
    end
    assert_match(/Author#posts/, error.message)
  end

  def test_reset_clears_the_tracker_between_requests
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(1)
    author = Author.first

    author.posts.to_a
    Facet::Orm::NPlusOneDetector.reset!
    author.posts.to_a
    Facet::Orm::NPlusOneDetector.report!

    assert_empty @io.string, 'reset! between requests must not let counts carry over'
  end

  def test_context_is_included_in_the_warning_line
    Facet::Orm::NPlusOneDetector.enable!(threshold: 2, io: @io)
    create_authors_with_posts(2)

    Author.all.to_a.each { |author| author.posts.to_a }
    Facet::Orm::NPlusOneDetector.report!(method: 'GET', path: '/authors')

    assert_match(%r{method=\"GET\" path=\"/authors\"}, @io.string)
  end
end
