require_relative 'orm/store'
require_relative 'orm/transactions'
require_relative 'orm/errors'
require_relative 'orm/type_casting'
require_relative 'orm/attributes'
require_relative 'orm/query/predicates'
require_relative 'orm/query/condition_node'
require_relative 'orm/pagination'
require_relative 'orm/serialization'
require_relative 'orm/enum'
require_relative 'orm/relation'
require_relative 'orm/validatable'
require_relative 'orm/callbacks'
require_relative 'orm/dirty'
require_relative 'orm/locking'
require_relative 'orm/pessimistic'
require_relative 'orm/paranoia'
require_relative 'orm/list_position'
require_relative 'orm/secure_password'
require_relative 'orm/secure_token'
require_relative 'orm/token_for'
require_relative 'orm/encryption'
require_relative 'orm/habtm_collection'
require_relative 'orm/n_plus_one_detector'
require_relative 'orm/associable'
require_relative 'orm/nested_attributes'
require_relative 'orm/model'
require_relative 'orm/migration'
require_relative 'orm/migrator'

module Facet
  module Orm
    class << self
      def connect(path)
        @store = Store.new(path)
      end

      def store
        @store || raise('Facet::Orm.connect(path) was not called yet')
      end

      def migrator(migrations_path)
        Migrator.new(store, migrations_path)
      end

      def transaction(&block)
        store.transaction_with_callbacks(&block)
      end
    end
  end
end
