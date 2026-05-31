require 'fileutils'
require 'time'

module Prism
  class Cli
    class UsageError < StandardError; end

    ServerScript = <<~'RUBY'
      require_relative '../app'

      server = Prism::Server.new(APP_CLASS, port: (ARGV[0] || 3000).to_i).start
      puts "listening on #{server.url}"
      trap('INT') { server.stop; exit }
      sleep
    RUBY

    def initialize(root = Dir.pwd)
      @root = root
    end

    def run(argv)
      command, *rest = argv
      case command
      when 'new' then new_app(rest.first || raise(UsageError, 'usage: prism new APP_NAME'))
      when 'generate', 'g' then generate(rest)
      when 'jobs' then jobs(rest)
      when 'assets:precompile' then assets_precompile(rest)
      when 'console', 'c' then console(rest)
      when 'routes' then routes(rest)
      when 'db:migrate' then db_migrate(rest)
      when 'db:rollback' then db_rollback(rest)
      when 'db:status' then db_status(rest)
      when 'db:seed' then db_seed(rest)
      else raise UsageError, "unknown command #{command.inspect}"
      end
    end

    # Applies every pending migration directly against a PStore file, the
    # same work `Orm.migrator(...).migrate!` does when a generated app.rb
    # boots - but as a standalone step that does not require loading the
    # rest of the application (no controllers, no server), mirroring `rails
    # db:migrate`. Useful on its own for apps that do not auto-migrate at
    # boot, and it is the only way to inspect/rewind migrations (db:status,
    # db:rollback below) without booting an app that would immediately
    # re-apply everything pending anyway.
    def db_migrate(args, out: $stdout)
      migrator = build_migrator(parse_db_options(args))
      applied = migrator.migrate!
      if applied.empty?
        out.puts '[prism db:migrate] no pending migrations'
      else
        applied.each { |version| out.puts "[prism db:migrate] migrated #{version}" }
      end
      applied
    end

    # Reverts the most recently applied migration(s), like `rails
    # db:rollback STEP=n` - `--step=N` picks how many to undo (default 1).
    def db_rollback(args, out: $stdout)
      options = parse_db_options(args)
      migrator = build_migrator(options)
      reverted = migrator.rollback!(options[:step])
      if reverted.empty?
        out.puts '[prism db:rollback] nothing to roll back'
      else
        reverted.each { |version| out.puts "[prism db:rollback] rolled back #{version}" }
      end
      reverted
    end

    # Lists every migration file found under --migrations next to whether
    # it has been applied to --database, like `rails db:migrate:status`.
    def db_status(args, out: $stdout)
      migrator = build_migrator(parse_db_options(args))
      status = migrator.status
      rows = status.map { |entry, applied| [applied ? 'up' : 'down', entry.version, entry.name] }
      header = %w[STATUS VERSION NAME]
      widths = header.each_index.map { |i| ([header[i].length] + rows.map { |row| row[i].length }).max }
      out.puts format_row(header, widths)
      rows.each { |row| out.puts format_row(row, widths) }
      status
    end

    # Loads the application (via --require, same flag shape as `jobs work`/
    # `console`) and then `load`s --file (default db/seeds.rb) as plain Ruby,
    # like `rails db:seed`. Deliberately `load` rather than `require`: a
    # seeds file has no meaningful "already loaded" state of its own (unlike
    # a model or controller file, it is not a class/module definition but a
    # sequence of side effects), so a second `db:seed` run - or a console/
    # test process that seeds more than once - must re-execute it, not
    # silently no-op the way `require` would after the first call already
    # loaded that exact path.
    #
    # Idempotency of what the seeds file actually does (find_or_create_by
    # vs. create!, etc.) is the app's concern, not this command's - same
    # division of responsibility Rails draws. A missing seeds file is not an
    # error: plenty of apps never have one, and `prism new` does not
    # generate a stub, so failing here would make db:seed unusable as a
    # step in a deploy script unless every app remembered to create an empty
    # placeholder first.
    def db_seed(args, out: $stdout)
      options = parse_seed_options(args)
      options[:require].each { |path| require File.expand_path(path, @root) }

      seeds_path = File.expand_path(options[:file], @root)
      unless File.exist?(seeds_path)
        out.puts "[prism db:seed] no seeds file at #{options[:file]}"
        return false
      end

      load seeds_path
      out.puts "[prism db:seed] seeded from #{options[:file]}"
      true
    end

    # Lists every route registered on a loaded Application subclass, like
    # `rails routes`: NAME, VERB, PATH and the controller#action (or
    # "(block)" for routes defined inline rather than via `to:`) it
    # dispatches to, in registration order (the same order the router tries
    # them in, which matters when patterns overlap). Mounted Rack apps
    # (`mount`) are listed separately underneath since they do not carry a
    # single verb/action - only a prefix and whatever app answers under it.
    def routes(args, out: $stdout)
      options = parse_routes_options(args)
      loaded_before = Application.subclasses
      options[:require].each { |path| require File.expand_path(path, @root) }
      newly_loaded = Application.subclasses - loaded_before

      app_class = resolve_app_class(options[:app], newly_loaded)
      print_routes(app_class.router, out)
      app_class
    end

    # A minimal `rails console`-style REPL: loads the application (via
    # --require, same flag shape as `jobs work`) and evaluates one line of
    # Ruby at a time against a binding that survives across lines, so a
    # local variable assigned on one line is still visible on the next -
    # e.g. `post = Post.first` then `post.title`. Deliberately single-line
    # (no heredoc/multi-line statement support) and has no history/tab
    # completion, unlike a real irb - this is a REPL, not a terminal editor;
    # it reads whatever `input` yields line by line, which makes it just as
    # easy to drive from a real TTY as from a StringIO in tests.
    def console(args, input: $stdin, out: $stdout)
      options = parse_console_options(args)
      options[:require].each { |path| require File.expand_path(path, @root) }

      session = Object.new
      session_binding = session.instance_eval { binding }

      prompt = options[:prompt]
      out.print(prompt)
      input.each_line do |line|
        line = line.chomp
        stripped = line.strip
        if %w[exit quit].include?(stripped)
          break
        elsif stripped.empty?
          out.print(prompt)
          next
        end

        begin
          result = session_binding.eval(line, '(console)')
          out.puts "=> #{result.inspect}"
        rescue StandardError, ScriptError => e
          out.puts "Error: #{e.class}: #{e.message}"
        end
        out.print(prompt)
      end
      out.puts
      nil
    end

    # Runs Assets::Compiler directly - fingerprints every file under
    # --source into --output plus a manifest.json - without booting the
    # rest of the application (no Orm.connect, no migrations, no server).
    # This is the missing deploy-time step Application#enable_assets never
    # covered on its own: enable_assets compiles as a side effect of
    # loading app.rb, which also means the ONLY way to precompile assets
    # before this was to boot the entire app (database connection and all)
    # just to get the compiled files onto disk. Mirrors `rake
    # assets:precompile` in Rails: a standalone step meant to run once
    # during deploy, before the server process starts.
    def assets_precompile(args, out: $stdout)
      options = parse_assets_precompile_options(args)
      source = File.expand_path(options[:source], @root)
      output = File.expand_path(options[:output], @root)
      manifest = Assets::Compiler.new(source: source, output: output).compile!
      out.puts "[prism assets:precompile] compiled #{manifest.to_h.size} file(s) into #{output}"
      manifest
    end

    # Runs a Jobs::Worker as a long-lived daemon: polls the queue, drains
    # every ready job, sleeps `interval` seconds, repeats until SIGINT/SIGTERM
    # (or forever with --once/--max-cycles for scripted/finite runs). Returns
    # the number of poll cycles executed, mainly so callers/tests can assert
    # on it without needing a real infinite loop.
    def jobs_work(args, out: $stdout)
      options = parse_jobs_work_options(args)
      options[:require].each { |path| require File.expand_path(path, @root) }

      pidfile = options[:pidfile] && File.expand_path(options[:pidfile], @root)
      write_pidfile(pidfile) if pidfile

      queue = Jobs::Queue.new(File.expand_path(options[:file], @root))
      worker = Jobs::Worker.new(
        queue,
        queue_name: options[:queue_name],
        error_handler: lambda do |error, job|
          warn "[prism jobs] job #{job[:id]} (#{job[:job_class]}) failed: #{error.message}"
        end
      )

      running = true
      trap('INT') { running = false }
      trap('TERM') { running = false }

      cycles = 0
      loop do
        processed = worker.work_off
        out.puts "[prism jobs] processed #{processed} job(s)" if options[:verbose] && processed.positive?
        cycles += 1
        break if options[:once]
        break if options[:max_cycles] && cycles >= options[:max_cycles]
        break unless running
        sleep(options[:interval])
        break unless running
      end
      cycles
    ensure
      remove_pidfile(pidfile) if pidfile
    end

    # Refuses to start a second daemon against the same pidfile while a
    # process recorded in it is still alive (mirrors the classic
    # pidfile-lock pattern used by unicorn/sidekiq); a pidfile left behind
    # by a process that crashed without cleaning up (stale pid, nothing
    # answers Process.kill(0, ...)) is silently reclaimed instead of
    # blocking every future start forever.
    def write_pidfile(pidfile)
      if File.exist?(pidfile)
        existing_pid = File.read(pidfile).strip.to_i
        if existing_pid.positive? && process_alive?(existing_pid)
          raise UsageError, "jobs worker already running (pid #{existing_pid}, pidfile #{pidfile})"
        end
      end
      FileUtils.mkdir_p(File.dirname(pidfile))
      File.write(pidfile, Process.pid.to_s)
    end

    def remove_pidfile(pidfile)
      File.delete(pidfile) if File.exist?(pidfile) && File.read(pidfile).strip.to_i == Process.pid
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def new_app(name)
      app_dir = File.join(@root, name)
      raise UsageError, "#{app_dir} already exists" if Dir.exist?(app_dir)

      %w[app/controllers app/models app/views/layouts db/migrate public bin].each do |subdir|
        FileUtils.mkdir_p(File.join(app_dir, subdir))
      end

      write_file(File.join(app_dir, 'app', 'views', 'layouts', 'application.erb'), layout_template)
      write_file(File.join(app_dir, 'app.rb'), app_boot_template(name))
      write_file(File.join(app_dir, 'config.ru'), config_ru_template(name))
      write_file(File.join(app_dir, 'bin', 'server'), ServerScript.sub('APP_CLASS', Inflector.camelize(name)))
      File.chmod(0o755, File.join(app_dir, 'bin', 'server'))
      app_dir
    end

    def generate_migration(name, fields = [])
      raise UsageError, 'usage: prism generate migration NAME [field:type ...]' unless name
      version = next_migration_version
      class_name = Inflector.camelize(name)
      path = File.join(@root, 'db', 'migrate', "#{version}_#{Inflector.underscore(name)}.rb")
      write_file(path, migration_template(class_name, name, fields))
      path
    end

    def generate_model(name, fields = [])
      raise UsageError, 'usage: prism generate model NAME [field:type ...]' unless name
      class_name = Inflector.camelize(name)
      model_path = File.join(@root, 'app', 'models', "#{Inflector.underscore(name)}.rb")
      write_file(model_path, model_template(class_name))
      migration_path = generate_migration("create_#{Inflector.tableize(class_name)}", fields)
      [model_path, migration_path]
    end

    private

    def generate(rest)
      kind, name, *fields = rest
      case kind
      when 'migration' then generate_migration(name, fields)
      when 'model' then generate_model(name, fields)
      else raise UsageError, "unknown generator #{kind.inspect}"
      end
    end

    def jobs(rest)
      subcommand, *args = rest
      case subcommand
      when 'work' then jobs_work(args)
      else raise UsageError, "unknown jobs subcommand #{subcommand.inspect}"
      end
    end

    def parse_jobs_work_options(args)
      options = { file: 'db/jobs.pstore', interval: 1.0, queue_name: nil, once: false,
                  max_cycles: nil, verbose: false, require: [], pidfile: nil }
      args.each do |arg|
        case arg
        when '--once' then options[:once] = true
        when '--verbose' then options[:verbose] = true
        when /\A--file=(.+)\z/ then options[:file] = Regexp.last_match(1)
        when /\A--interval=(.+)\z/ then options[:interval] = Regexp.last_match(1).to_f
        when /\A--queue=(.+)\z/ then options[:queue_name] = Regexp.last_match(1)
        when /\A--max-cycles=(\d+)\z/ then options[:max_cycles] = Regexp.last_match(1).to_i
        when /\A--require=(.+)\z/ then options[:require] << Regexp.last_match(1)
        when /\A--pidfile=(.+)\z/ then options[:pidfile] = Regexp.last_match(1)
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      options
    end

    def parse_routes_options(args)
      options = { require: [], app: nil }
      args.each do |arg|
        case arg
        when /\A--require=(.+)\z/ then options[:require] << Regexp.last_match(1)
        when /\A--app=(.+)\z/ then options[:app] = Regexp.last_match(1)
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      options
    end

    # `--app` picks by name when a project loads more than one
    # Prism::Application subclass (e.g. a host app plus a mounted engine).
    # Auto-detection deliberately looks only at subclasses newly defined by
    # THIS call's --require, not at Application.subclasses as a whole: a
    # Ruby class is never garbage-collected just because its constant gets
    # undefined, so in a long-lived process (the test suite, an irb/console
    # session reloading code) every Application subclass ever defined stays
    # in that list forever - scanning it whole would make auto-detection
    # increasingly wrong the longer the process lives, not just after a
    # fresh `ruby bin/prism routes --require=app.rb` (where it happens to
    # equal "the one class app.rb just defined" anyway).
    def resolve_app_class(explicit_name, newly_loaded)
      return Object.const_get(explicit_name) if explicit_name
      raise UsageError, 'no Prism::Application subclass loaded (pass --require=FILE or --app=ClassName)' if newly_loaded.empty?
      if newly_loaded.size > 1
        names = newly_loaded.map(&:name).join(', ')
        raise UsageError, "multiple Prism::Application subclasses loaded (#{names}) - pick one with --app=ClassName"
      end
      newly_loaded.first
    end

    def print_routes(router, out)
      rows = router.routes.map do |route|
        [route.method, route.pattern, route_target(route), route.name ? "#{route.name}_path" : '']
      end
      header = %w[VERB PATH TO NAME]
      widths = header.each_index.map { |i| ([header[i].length] + rows.map { |row| row[i].length }).max }

      out.puts format_row(header, widths)
      rows.each { |row| out.puts format_row(row, widths) }

      router.mounts.each do |prefix, mounted_app|
        out.puts "MOUNT  #{prefix} -> #{mounted_app.class}"
      end
      nil
    end

    def route_target(route)
      route.controller_route? ? "#{route.controller_name}##{route.action_name}" : '(block)'
    end

    def format_row(row, widths)
      row.each_index.map { |i| row[i].ljust(widths[i]) }.join('  ').rstrip
    end

    def parse_console_options(args)
      options = { require: [], prompt: 'prism> ' }
      args.each do |arg|
        case arg
        when /\A--require=(.+)\z/ then options[:require] << Regexp.last_match(1)
        when /\A--prompt=(.+)\z/ then options[:prompt] = Regexp.last_match(1)
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      options
    end

    def parse_seed_options(args)
      options = { require: [], file: 'db/seeds.rb' }
      args.each do |arg|
        case arg
        when /\A--require=(.+)\z/ then options[:require] << Regexp.last_match(1)
        when /\A--file=(.+)\z/ then options[:file] = Regexp.last_match(1)
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      options
    end

    def parse_db_options(args)
      options = { database: 'db/development.pstore', migrations: 'db/migrate', step: 1 }
      args.each do |arg|
        case arg
        when /\A--database=(.+)\z/ then options[:database] = Regexp.last_match(1)
        when /\A--migrations=(.+)\z/ then options[:migrations] = Regexp.last_match(1)
        when /\A--step=(\d+)\z/ then options[:step] = Regexp.last_match(1).to_i
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      options
    end

    def build_migrator(options)
      store = Orm::Store.new(File.expand_path(options[:database], @root))
      Orm::Migrator.new(store, File.expand_path(options[:migrations], @root))
    end

    def parse_assets_precompile_options(args)
      options = {}
      args.each do |arg|
        case arg
        when /\A--source=(.+)\z/ then options[:source] = Regexp.last_match(1)
        when /\A--output=(.+)\z/ then options[:output] = Regexp.last_match(1)
        else raise UsageError, "unknown option #{arg.inspect}"
        end
      end
      raise UsageError, 'usage: prism assets:precompile --source=DIR --output=DIR' unless options[:source] && options[:output]
      options
    end

    def next_migration_version
      version = Time.now.utc.strftime('%Y%m%d%H%M%S')
      version = (version.to_i + 1).to_s while File.exist?(File.join(@root, 'db', 'migrate')) &&
                                             Dir.glob(File.join(@root, 'db', 'migrate', "#{version}_*.rb")).any?
      version
    end

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def layout_template
      <<~ERB
        <!doctype html>
        <html>
          <head><title><%= defined?(title) ? title : 'Prism App' %></title></head>
          <body><%== content %></body>
        </html>
      ERB
    end

    def app_boot_template(name)
      class_name = Inflector.camelize(name)
      <<~RUBY
        require 'prism'

        APP_ROOT = __dir__

        Prism::Orm.connect(File.join(APP_ROOT, 'db', 'development.pstore'))
        Prism::Orm.migrator(File.join(APP_ROOT, 'db', 'migrate')).migrate!

        Prism::Controller.views_root(File.join(APP_ROOT, 'app', 'views'))
        Prism::Controller.layout(:application)

        Dir[File.join(APP_ROOT, 'app', 'models', '*.rb')].sort.each { |file| require file }
        Dir[File.join(APP_ROOT, 'app', 'controllers', '*.rb')].sort.each { |file| require file }

        class #{class_name} < Prism::Application
          set :views, File.join(APP_ROOT, 'app', 'views')
          use Prism::Middleware::Logger
          use Prism::Middleware::ParamsParser
          use Prism::Middleware::Static, root: File.join(APP_ROOT, 'public')
        end
      RUBY
    end

    def config_ru_template(name)
      <<~RUBY
        require_relative 'app'

        run #{Inflector.camelize(name)}
      RUBY
    end

    def migration_template(class_name, name, fields)
      match = name.match(/\Acreate_(.+)\z/i)
      return plain_migration_template(class_name) unless match

      table = match[1]
      columns = indent(fields.map { |field| field_line(field) }.join("\n"), 6)
      <<~RUBY
        class #{class_name} < Prism::Orm::Migration
          def up
            create_table :#{table} do |t|
        #{columns}
              t.timestamps
            end
          end

          def down
            drop_table :#{table}
          end
        end
      RUBY
    end

    def plain_migration_template(class_name)
      <<~RUBY
        class #{class_name} < Prism::Orm::Migration
          def up
          end

          def down
          end
        end
      RUBY
    end

    def field_line(field)
      column, type = field.split(':', 2)
      "t.#{type || 'string'} :#{column}"
    end

    def indent(text, spaces)
      return '' if text.empty?
      text.lines.map { |line| (' ' * spaces) + line }.join
    end

    def model_template(class_name)
      <<~RUBY
        class #{class_name} < Prism::Orm::Model
        end
      RUBY
    end
  end
end
