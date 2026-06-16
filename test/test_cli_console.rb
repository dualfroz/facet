require 'minitest/autorun'
require 'prism'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class CliConsoleTest < Minitest::Test
  def setup
    @workdir = Dir.mktmpdir('prism-cli-console')
    @cli = Prism::Cli.new(@workdir)
  end

  def teardown
    FileUtils.remove_entry(@workdir)
  end

  def run_console(script, extra_args = [])
    input = StringIO.new(script)
    out = StringIO.new
    @cli.console(extra_args, input: input, out: out)
    out.string
  end

  def test_evaluates_a_simple_expression
    output = run_console("1 + 1\n")
    assert_includes output, '=> 2'
  end

  def test_prints_prompt_before_each_line_and_at_the_end
    output = run_console("1\n2\n")
    assert_equal 3, output.scan('prism> ').size
  end

  def test_local_variables_persist_across_lines
    output = run_console("x = 5\nx * 2\n")
    assert_includes output, '=> 5'
    assert_includes output, '=> 10'
  end

  def test_custom_prompt_option
    output = run_console("1\n", ['--prompt=blog> '])
    assert_includes output, 'blog> '
    refute_includes output, 'prism> '
  end

  def test_syntax_error_is_reported_without_aborting_the_session
    output = run_console("def broken(\n1 + 1\n")
    assert_includes output, 'Error:'
    assert_includes output, '=> 2'
  end

  def test_runtime_error_is_reported_without_aborting_the_session
    output = run_console("raise ArgumentError, 'boom'\n1 + 1\n")
    assert_includes output, 'Error: ArgumentError: boom'
    assert_includes output, '=> 2'
  end

  def test_exit_stops_the_session_before_reading_further_lines
    output = run_console("exit\n1 + 1\n")
    refute_includes output, '=> 2'
  end

  def test_quit_stops_the_session
    output = run_console("quit\n")
    refute_includes output, 'Error'
  end

  def test_blank_line_is_skipped_without_error
    output = run_console("\n1 + 1\n")
    refute_includes output, 'Error'
    assert_includes output, '=> 2'
  end

  def test_unknown_option_raises_usage_error
    assert_raises(Prism::Cli::UsageError) { @cli.console(['--bogus'], input: StringIO.new, out: StringIO.new) }
  end

  def test_require_option_loads_a_file_before_the_session_starts
    fixture = File.join(@workdir, 'greeting.rb')
    File.write(fixture, "CONSOLE_TEST_GREETING = 'hello from fixture'\n")

    output = run_console("CONSOLE_TEST_GREETING\n", ['--require=greeting.rb'])
    assert_includes output, '=> "hello from fixture"'
  ensure
    Object.send(:remove_const, :CONSOLE_TEST_GREETING) if Object.const_defined?(:CONSOLE_TEST_GREETING)
  end

  def test_run_dispatches_console_command
    output = StringIO.new
    input = StringIO.new("1 + 1\n")
    @cli.console([], input: input, out: output)
    assert_includes output.string, '=> 2'
  end

  def test_c_alias_is_recognized_by_run_dispatch
    assert_raises(Prism::Cli::UsageError) { @cli.run(%w[c --bogus]) }
  end
end
