module Prism
  # Wires Policy lookups into a Controller, the request-cycle counterpart
  # to Policy the way Authenticatable is to Orm::SecurePassword:
  #
  #   class PostsController < ApplicationController
  #     include Prism::Authorizable
  #     rescue_from Prism::Policy::NotAuthorizedError, with: :forbidden
  #
  #     def destroy
  #       post = Post.find(params['id'])
  #       authorize(post)
  #       post.destroy
  #       ...
  #     end
  #
  #     private
  #
  #     def forbidden(_exception)
  #       halt(403, 'not allowed')
  #     end
  #   end
  #
  # `authorize` defaults the query to "#{action_name}?" (`destroy?` inside
  # a `destroy` action), so most call sites don't have to name it.
  module Authorizable
    def authorize(record, query = nil)
      query ||= "#{action_name}?"
      raise Policy::NotAuthorizedError.new(record, query) unless policy(record).public_send(query)
      record
    end

    def policy(record)
      Policy.for_record(record).new(current_user, record)
    end

    def policy_scope(scope)
      Policy.for_record(scope).const_get(:Scope).new(current_user, scope).resolve
    end
  end
end
