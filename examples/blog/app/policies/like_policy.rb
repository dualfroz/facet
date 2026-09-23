class LikePolicy < Facet::Policy
  def destroy?
    user && record.user_id == user.id
  end
end
