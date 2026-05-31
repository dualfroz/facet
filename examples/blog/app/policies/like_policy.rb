class LikePolicy < Prism::Policy
  def destroy?
    user && record.user_id == user.id
  end
end
