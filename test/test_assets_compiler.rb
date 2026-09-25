require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'

class AssetsCompilerTest < Minitest::Test
  def test_compiles_files_into_content_addressed_names
    with_source do |source, output|
      write(source, 'application.css', 'body { color: red; }')

      manifest = Facet::Assets::Compiler.new(source: source, output: output).compile!

      fingerprinted = manifest.lookup('application.css')
      assert_match(/\Aapplication-[0-9a-f]{8}\.css\z/, fingerprinted)
      assert_equal 'body { color: red; }', File.read(File.join(output, fingerprinted))
    end
  end

  def test_same_content_produces_the_same_fingerprint_across_compiles
    with_source do |source, output|
      write(source, 'app.js', 'console.log(1);')
      compiler = Facet::Assets::Compiler.new(source: source, output: output)

      first = compiler.compile!.lookup('app.js')
      second = compiler.compile!.lookup('app.js')

      assert_equal first, second
    end
  end

  def test_changed_content_produces_a_different_fingerprint
    with_source do |source, output|
      write(source, 'app.js', 'console.log(1);')
      compiler = Facet::Assets::Compiler.new(source: source, output: output)
      first = compiler.compile!.lookup('app.js')

      write(source, 'app.js', 'console.log(2);')
      second = compiler.compile!.lookup('app.js')

      refute_equal first, second
    end
  end

  def test_stale_fingerprinted_files_are_removed_on_recompile
    with_source do |source, output|
      write(source, 'app.js', 'console.log(1);')
      compiler = Facet::Assets::Compiler.new(source: source, output: output)
      old_fingerprinted = compiler.compile!.lookup('app.js')
      old_path = File.join(output, old_fingerprinted)
      assert File.file?(old_path)

      write(source, 'app.js', 'console.log(2);')
      compiler.compile!

      refute File.file?(old_path), 'stale fingerprinted file should have been cleaned up'
    end
  end

  def test_unchanged_files_are_left_alone_when_a_sibling_changes
    with_source do |source, output|
      write(source, 'a.css', 'a')
      write(source, 'b.css', 'b')
      compiler = Facet::Assets::Compiler.new(source: source, output: output)
      first = compiler.compile!
      a_fingerprint = first.lookup('a.css')

      write(source, 'b.css', 'b-changed')
      second = compiler.compile!

      assert_equal a_fingerprint, second.lookup('a.css')
      assert File.file?(File.join(output, a_fingerprint))
    end
  end

  def test_preserves_subdirectory_structure_as_logical_paths
    with_source do |source, output|
      write(source, 'css/nested/theme.css', '.x{}')

      manifest = Facet::Assets::Compiler.new(source: source, output: output).compile!

      fingerprinted = manifest.lookup('css/nested/theme.css')
      assert_match(%r{\Acss/nested/theme-[0-9a-f]{8}\.css\z}, fingerprinted)
      assert File.file?(File.join(output, fingerprinted))
    end
  end

  def test_writes_manifest_json_to_the_output_directory
    with_source do |source, output|
      write(source, 'a.css', 'a')
      Facet::Assets::Compiler.new(source: source, output: output).compile!

      manifest_path = File.join(output, 'manifest.json')
      assert File.file?(manifest_path)
      parsed = JSON.parse(File.read(manifest_path))
      assert_match(/\Aa-[0-9a-f]{8}\.css\z/, parsed['a.css'])
    end
  end

  private

  def with_source
    Dir.mktmpdir do |root|
      source = File.join(root, 'source')
      output = File.join(root, 'output')
      FileUtils.mkdir_p(source)
      yield source, output
    end
  end

  def write(source, relative, content)
    path = File.join(source, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
