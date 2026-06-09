module Prism
  # Pundit-lite authorization: a Policy pairs a user with a record and
  # answers yes/no permission questions about it, keeping "who can do
  # what" out of models and controllers. A PostPolicy answers questions
  # about a Post (`edit?`, `destroy?`); its nested Scope narrows a
  # collection down to what a given user may see at all.
  #
  #   class PostPolicy < Prism::Policy
  #     def destroy?
  #       user && record.user_id == user.id
  #     end
  #   end
  #
  # Any query left undefined answers false (default-deny), so a policy only
  # has to spell out what it allows.
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

    # Narrows a collection (an ORM Relation or any enumerable) down to what
    # `user` may see, e.g. `PostPolicy::Scope.new(current_user, Post.all).resolve`.
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
      # PostPolicy for a Post/Post instance, Admin::PostPolicy for
      # Admin::Post - mirrors how Controller#controller_path and
      # Authenticatable resolve names lazily instead of hardcoding them.
      def for_record(record)
        klass = record.is_a?(Class) ? record : record.class
        Object.const_get("#{klass.name}Policy")
      end
    end
  end
end
