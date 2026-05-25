module Prism
  module Orm
    class Migrator
      Entry = Struct.new(:version, :name, :path)

      def initialize(store, migrations_path)
        @store = store
        @migrations_path = migrations_path
      end

      def entries
        Dir.glob(File.join(@migrations_path, '*.rb')).sort.map do |path|
          version, name = File.basename(path, '.rb').split('_', 2)
          Entry.new(version, name, path)
        end
      end

      def pending
        applied = @store.applied_migrations
        entries.reject { |entry| applied.include?(entry.version) }
      end

      def migrate!
        applied = pending.map { |entry| apply(entry) }
        applied.map(&:version)
      end

      def rollback!(steps = 1)
        versions = @store.applied_migrations.sort.last(steps).reverse
        versions.map do |version|
          entry = entries.find { |candidate| candidate.version == version }
          next unless entry
          revert(entry)
          entry.version
        end.compact
      end

      private

      def apply(entry)
        migration = load_migration(entry)
        migration.up
        @store.record_migration(entry.version)
        entry
      end

      def revert(entry)
        migration = load_migration(entry)
        migration.down
        @store.forget_migration(entry.version)
      end

      def load_migration(entry)
        class_name = Inflector.camelize(entry.name)
        load entry.path
        Object.const_get(class_name).new(@store)
      end
    end
  end
end
