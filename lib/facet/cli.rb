require 'fileutils'
require 'time'

module Facet
  class Cli
    class UsageError < StandardError; end

    ServerScript = <<~'RUBY'
      require_relative '../app'

      server = Facet::Server.new(APP_CLASS, port: (ARGV[0] || 3000).to_i).start
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
      when 'new' then new_app(rest.first || raise(UsageError, 'usage: facet new APP_NAME'))
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

    def db_migrate(args, out: $stdout)
      migrator = build_migrator(parse_db_options(args))
      applied = migrator.migrate!
      if applied.empty?
        out.puts '[facet db:migrate] no pending migrations'
      else
        applied.each { |version| out.puts "[facet db:migrate] migrated #{version}" }
      end
      applied
    end

    def db_rollback(args, out: $stdout)
      options = parse_db_options(args)
      migrator = build_migrator(options)
      reverted = migrator.rollback!(options[:step])
      if reverted.empty?
        out.puts '[facet db:rollback] nothing to roll back'
      else
        reverted.each { |version| out.puts "[facet db:rollback] rolled back #{version}" }
      end
      reverted
    end

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

    def db_seed(args, out: $stdout)
      options = parse_seed_options(args)
      options[:require].each { |path| require File.expand_path(path, @root) }

      seeds_path = File.expand_path(options[:file], @root)
      unless File.exist?(seeds_path)
        out.puts "[facet db:seed] no seeds file at #{options[:file]}"
        return false
      end

      load seeds_path
      out.puts "[facet db:seed] seeded from #{options[:file]}"
      true
    end

    def routes(args, out: $stdout)
      options = parse_routes_options(args)
      loaded_before = Application.subclasses
      options[:require].each { |path| require File.expand_path(path, @root) }
      newly_loaded = Application.subclasses - loaded_before

      app_class = resolve_app_class(options[:app], newly_loaded)
      print_routes(app_class.router, out)
      app_class
    end

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

    def assets_precompile(args, out: $stdout)
      options = parse_assets_precompile_options(args)
      source = File.expand_path(options[:source], @root)
      output = File.expand_path(options[:output], @root)
      manifest = Assets::Compiler.new(source: source, output: output).compile!
      out.puts "[facet assets:precompile] compiled #{manifest.to_h.size} file(s) into #{output}"
      manifest
    end

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
          warn "[facet jobs] job #{job[:id]} (#{job[:job_class]}) failed: #{error.message}"
        end
      )

      running = true
      trap('INT') { running = false }
      trap('TERM') { running = false }

      cycles = 0
      loop do
        processed = worker.work_off
        out.puts "[facet jobs] processed #{processed} job(s)" if options[:verbose] && processed.positive?
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
      raise UsageError, 'usage: facet generate migration NAME [field:type ...]' unless name
      version = next_migration_version
      class_name = Inflector.camelize(name)
      path = File.join(@root, 'db', 'migrate', "#{version}_#{Inflector.underscore(name)}.rb")
      write_file(path, migration_template(class_name, name, fields))
      path
    end

    def generate_model(name, fields = [])
      raise UsageError, 'usage: facet generate model NAME [field:type ...]' unless name
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

    def resolve_app_class(explicit_name, newly_loaded)
      return Object.const_get(explicit_name) if explicit_name
      raise UsageError, 'no Facet::Application subclass loaded (pass --require=FILE or --app=ClassName)' if newly_loaded.empty?
      if newly_loaded.size > 1
        names = newly_loaded.map(&:name).join(', ')
        raise UsageError, "multiple Facet::Application subclasses loaded (#{names}) - pick one with --app=ClassName"
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
      options = { require: [], prompt: 'facet> ' }
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
      raise UsageError, 'usage: facet assets:precompile --source=DIR --output=DIR' unless options[:source] && options[:output]
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
          <head><title><%= defined?(title) ? title : 'Facet App' %></title></head>
          <body><%== content %></body>
        </html>
      ERB
    end

    def app_boot_template(name)
      class_name = Inflector.camelize(name)
      <<~RUBY
        require 'facet'

        APP_ROOT = __dir__

        Facet::Orm.connect(File.join(APP_ROOT, 'db', 'development.pstore'))
        Facet::Orm.migrator(File.join(APP_ROOT, 'db', 'migrate')).migrate!

        Facet::Controller.views_root(File.join(APP_ROOT, 'app', 'views'))
        Facet::Controller.layout(:application)

        Dir[File.join(APP_ROOT, 'app', 'models', '*.rb')].sort.each { |file| require file }
        Dir[File.join(APP_ROOT, 'app', 'controllers', '*.rb')].sort.each { |file| require file }

        class #{class_name} < Facet::Application
          set :views, File.join(APP_ROOT, 'app', 'views')
          use Facet::Middleware::Logger
          use Facet::Middleware::ParamsParser
          use Facet::Middleware::Static, root: File.join(APP_ROOT, 'public')
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
        class #{class_name} < Facet::Orm::Migration
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
        class #{class_name} < Facet::Orm::Migration
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
        class #{class_name} < Facet::Orm::Model
        end
      RUBY
    end
  end
end
