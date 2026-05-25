require_relative 'orm/store'
require_relative 'orm/errors'
require_relative 'orm/relation'
require_relative 'orm/validatable'
require_relative 'orm/associable'
require_relative 'orm/model'
require_relative 'orm/migration'
require_relative 'orm/migrator'

module Prism
  module Orm
    class << self
      def connect(path)
        @store = Store.new(path)
      end

      def store
        @store || raise('Prism::Orm.connect(path) was not called yet')
      end

      def migrator(migrations_path)
        Migrator.new(store, migrations_path)
      end

      def transaction(&block)
        store.transaction(&block)
      end
    end
  end
end
