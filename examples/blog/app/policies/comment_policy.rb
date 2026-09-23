class CommentPolicy < Facet::Policy
  def update?
    user && record.user_id == user.id
  end

  def destroy?
    update?
  end

  def restore?
    update?
  end

  def approve?
    user && record.post.user_id == user.id
  end

  def reject?
    approve?
  end
end
