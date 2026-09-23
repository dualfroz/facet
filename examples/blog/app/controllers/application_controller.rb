class ApplicationController < Facet::Controller
  include Facet::Authenticatable
  include Facet::Authorizable

  layout :application
  protect_from_forgery
  authenticate_with model: User, unauthenticated_redirect_path: '/session/new', remember_sessions: LoginSession,
                     max_remember_sessions: 3
  rescue_from Facet::Policy::NotAuthorizedError, with: :forbidden

  def likes_count(record)
    record.likes_count
  end

  def current_user_like(record)
    return nil unless current_user
    record.likes.find { |like| like.user_id == current_user.id }
  end

  def current_user_claim(post)
    return nil unless current_user
    post.claims.find { |claim| claim.user_id == current_user.id }
  end

  def comment_post_label(comment)
    post = comment_post(comment)
    return t('comments.orphaned_post') if post.nil?
    post.deleted? ? t('comments.post_also_trashed', title: post.title) : post.title
  end

  def comment_post_linkable?(comment)
    post = comment_post(comment)
    post && !post.deleted?
  end

  def comment_post_slug(comment)
    comment_post(comment)&.to_param
  end

  private

  def comment_post(comment)
    @comment_post_cache ||= {}
    @comment_post_cache.fetch(comment.post_id) { @comment_post_cache[comment.post_id] = Post.with_deleted.find_by(id: comment.post_id) }
  end

  def jsonapi_error(status:, pointer:, title:, detail:)
    { status: status.to_s, source: { pointer: pointer }, title: title, detail: detail }
  end

  def respond_not_found(detail)
    respond_to do |format|
      format.html { halt(404, detail) }
      format.json { render_not_found(detail) }
    end
  end

  def forbidden(exception)
    flash[:notice] = t('errors.forbidden')
    redirect url_for(:post, slug: post_slug_for(exception.record))
  end

  def post_slug_for(record)
    case record
    when Comment then record.post.slug
    when Like then post_slug_for(record.likeable)
    else record.to_param
    end
  end
end
