module Facet
  class Policy
    class NotAuthorizedError < StandardError
      attr_reader :record, :query

      def initialize(record, query)
        @record = record
        @query = query
        super("#{record.class} not authorized for #{query}")
      end
    end

    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def method_missing(name, *args, &block)
      return false if args.empty? && !block && name.to_s.end_with?('?')
      super
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.end_with?('?') || super
    end

    class Scope
      attr_reader :user, :scope

      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        raise NotImplementedError, "#{self.class} must implement #resolve"
      end
    end

    class << self
      def for_record(record)
        klass = record.is_a?(Class) ? record : record.class
        Object.const_get("#{klass.name}Policy")
      end
    end
  end
end
