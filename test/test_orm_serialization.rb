require 'minitest/autorun'
require 'json'
require 'facet'
require 'tmpdir'

class OrmSerializationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-serialization-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authors, %w[id name email password_digest created_at])
    @store.create_table(:articles, %w[id author_id title body])

    author_class = Class.new(Facet::Orm::Model) do
      table_name :authors
      has_many :articles, class_name: 'Article', foreign_key: 'author_id'
      has_secure_password validations: false

      def greeting
        "hi #{name}"
      end
    end
    article_class = Class.new(Facet::Orm::Model) do
      table_name :articles
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'
    end
    [author_class, article_class].each { |klass| klass.store = @store }
    Object.const_set(:Author, author_class)
    Object.const_set(:Article, article_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Author Article].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_serializable_hash_returns_all_attributes_by_default
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    hash = author.serializable_hash
    assert_equal 'Ada', hash['name']
    assert_equal 'ada@example.com', hash['email']
    assert_equal author.id, hash['id']
  end

  def test_only_filters_to_named_attributes
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    hash = author.serializable_hash(only: :name)
    assert_equal({ 'name' => 'Ada' }, hash)
  end

  def test_except_removes_named_attributes
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    hash = author.serializable_hash(except: [:email, :created_at, :updated_at])
    assert_equal %w[id name], hash.keys.sort
  end

  def test_methods_option_adds_computed_values
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    hash = author.serializable_hash(only: :name, methods: :greeting)
    assert_equal 'hi Ada', hash['greeting']
  end

  def test_password_digest_is_hidden_from_json_by_default
    author = Author.create!(name: 'Ada', email: 'ada@example.com', password: 'sekret123')
    refute_nil author['password_digest']
    hash = author.serializable_hash
    refute hash.key?('password_digest'), 'password_digest must not leak through default serialization'
  end

  def test_explicit_only_can_override_the_default_hide
    author = Author.create!(name: 'Ada', email: 'ada@example.com', password: 'sekret123')
    hash = author.serializable_hash(only: %i[name password_digest])
    assert hash.key?('password_digest'), 'an explicit only: is a deliberate opt-in, it must win'
  end

  def test_as_json_stringifies_time_columns
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    assert_kind_of Time, author['created_at'], 'sanity check: raw attribute is a Time'
    json = author.as_json
    assert_kind_of String, json['created_at']
    assert_equal author['created_at'].iso8601, json['created_at']
  end

  def test_to_json_round_trips_through_json_generate
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    parsed = JSON.parse(author.to_json)
    assert_equal 'Ada', parsed['name']
    refute parsed.key?('password_digest')
  end

  def test_json_generate_on_a_bare_record_uses_to_json
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    parsed = JSON.parse(JSON.generate(author))
    assert_equal 'Ada', parsed['name']
  end

  def test_include_serializes_a_belongs_to_association
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    article = Article.create!(author_id: author.id, title: 'Hello', body: 'World')
    hash = article.serializable_hash(include: :author)
    assert_equal 'Ada', hash['author']['name']
  end

  def test_include_serializes_a_has_many_collection
    author = Author.create!(name: 'Ada', email: 'ada@example.com')
    Article.create!(author_id: author.id, title: 'One', body: 'x')
    Article.create!(author_id: author.id, title: 'Two', body: 'y')
    hash = author.serializable_hash(only: :name, include: { articles: { only: :title } })
    titles = hash['articles'].map { |row| row['title'] }
    assert_equal %w[One Two], titles.sort
  end

  def test_include_with_nil_belongs_to_yields_nil
    orphan = Article.create!(author_id: nil, title: 'Orphan', body: 'x')
    hash = orphan.serializable_hash(include: :author)
    assert_nil hash['author']
  end

  def test_relation_as_json_serializes_each_record
    Author.create!(name: 'Ada', email: 'a@example.com')
    Author.create!(name: 'Bea', email: 'b@example.com')
    rows = Author.all.as_json(only: :name)
    assert_equal [{ 'name' => 'Ada' }, { 'name' => 'Bea' }], rows.sort_by { |row| row['name'] }
  end

  def test_relation_to_json_produces_a_json_array_without_leaking_hidden_columns
    Author.create!(name: 'Ada', email: 'a@example.com', password: 'sekret123')
    parsed = JSON.parse(Author.all.to_json)
    assert_equal 1, parsed.size
    refute parsed.first.key?('password_digest')
  end

  def test_hide_from_json_is_inherited_by_subclasses
    base_class = Class.new(Facet::Orm::Model) { table_name :authors }
    base_class.hide_from_json(:email)
    Object.const_set(:BaseAuthor, base_class)
    sub_class = Class.new(base_class) { table_name :authors }
    Object.const_set(:SubAuthor, sub_class)
    sub_class.store = @store

    record = sub_class.create!(name: 'Ada', email: 'ada@example.com')
    refute record.serializable_hash.key?('email')
  ensure
    %i[BaseAuthor SubAuthor].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end
end
