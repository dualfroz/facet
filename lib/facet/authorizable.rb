module Facet
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
