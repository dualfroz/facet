require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmCacheKeyTest < Minitest::Test
  def setup
    Object.send(:remove_const, :Snippet) if Object.const_defined?(:Snippet)
    @dir = Dir.mktmpdir('prism-cache-key-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:snippets, %w[id body created_at updated_at])

    snippet_class = Class.new(Prism::Orm::Model) { table_name :snippets }
    snippet_class.store = @store
    Object.const_set(:Snippet, snippet_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :Snippet) if Object.const_defined?(:Snippet)
  end

  def test_cache_key_includes_table_name_and_id
    snippet = Snippet.create!(body: 'hello')
    assert_equal "snippets/#{snippet.id}-#{snippet.updated_at.to_i}", snippet.cache_key
  end

  def test_cache_key_changes_when_the_record_is_touched
    snippet = Snippet.create!(body: 'hello')
    original = snippet.cache_key
    sleep 1.01
    snippet.update!(body: 'goodbye')
    refute_equal original, snippet.cache_key
  end

  def test_cache_key_without_timestamps_falls_back_to_table_and_id
    Object.send(:remove_const, :Snippet)
    @store.create_table(:plain_snippets, %w[id body])
    plain_class = Class.new(Prism::Orm::Model) { table_name :plain_snippets }
    plain_class.store = @store
    Object.const_set(:Snippet, plain_class)

    snippet = Snippet.create!(body: 'hello')
    assert_equal "plain_snippets/#{snippet.id}", snippet.cache_key
  end
end
