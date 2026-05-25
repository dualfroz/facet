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
      else raise UsageError, "unknown command #{command.inspect}"
      end
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
