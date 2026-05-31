class CommentPolicy < Prism::Policy
  def update?
    user && record.user_id == user.id
  end

  def destroy?
    update?
  end

  def restore?
    update?
  end

  # Approving/rejecting is a moderation call, not an authorship one - it
  # belongs to whoever owns the post the comment hangs off of, same as the
  # nested-attributes moderation form on PostsController#update (which goes
  # through PostPolicy#update? instead, since that request targets the post).
  def approve?
    user && record.post.user_id == user.id
  end

  def reject?
    approve?
  end
end
