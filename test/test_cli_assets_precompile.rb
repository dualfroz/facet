require 'minitest/autorun'
require 'facet'
require 'tmpdir'
require 'fileutils'
require 'stringio'

class CliAssetsPrecompileTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-cli-assets')
    @cli = Facet::Cli.new(@dir)
    @source = File.join(@dir, 'app', 'assets')
    @output = File.join(@dir, 'public', 'assets')
    FileUtils.mkdir_p(File.join(@source, 'stylesheets'))
    File.write(File.join(@source, 'stylesheets', 'application.css'), 'body { color: red; }')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_precompiles_without_booting_an_application
    manifest = @cli.assets_precompile(['--source=app/assets', '--output=public/assets'], out: StringIO.new)
    logical = manifest.to_h.keys
    assert_equal ['stylesheets/application.css'], logical
    fingerprinted = manifest.lookup('stylesheets/application.css')
    assert_match(/\Astylesheets\/application-[0-9a-f]{8}\.css\z/, fingerprinted)
    assert File.exist?(File.join(@output, fingerprinted))
    assert File.exist?(File.join(@output, 'manifest.json'))
  end

  def test_prints_a_summary_to_the_given_output
    out = StringIO.new
    @cli.assets_precompile(['--source=app/assets', '--output=public/assets'], out: out)
    assert_match(/compiled 1 file\(s\) into/, out.string)
  end

  def test_recompiling_unchanged_content_reproduces_the_same_fingerprint_and_removes_nothing_stale
    first = @cli.assets_precompile(['--source=app/assets', '--output=public/assets'], out: StringIO.new)
    second = @cli.assets_precompile(['--source=app/assets', '--output=public/assets'], out: StringIO.new)
    assert_equal first.to_h, second.to_h
  end

  def test_raises_usage_error_without_required_options
    assert_raises(Facet::Cli::UsageError) { @cli.assets_precompile([]) }
    assert_raises(Facet::Cli::UsageError) { @cli.assets_precompile(['--source=app/assets']) }
  end

  def test_run_dispatches_the_assets_colon_precompile_command
    original_stdout = $stdout
    captured = StringIO.new
    $stdout = captured
    @cli.run(['assets:precompile', '--source=app/assets', '--output=public/assets'])
  ensure
    $stdout = original_stdout
    assert_match(/compiled 1 file\(s\)/, captured.string)
    assert File.exist?(File.join(@output, 'manifest.json'))
  end
end
