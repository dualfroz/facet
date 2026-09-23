class PostPolicy < Facet::Policy
  def update?
    user && record.user_id == user.id
  end

  def destroy?
    update?
  end

  def restore?
    update?
  end
end
