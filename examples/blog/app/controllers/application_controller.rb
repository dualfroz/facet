class ApplicationController < Prism::Controller
  include Prism::Authenticatable
  include Prism::Authorizable

  layout :application
  protect_from_forgery
  authenticate_with model: User, unauthenticated_redirect_path: '/session/new', remember_sessions: LoginSession,
                     max_remember_sessions: 3
  rescue_from Prism::Policy::NotAuthorizedError, with: :forbidden

  # How many likes a post or comment has, and the current visitor's own
  # Like on it (if any) - used by views to decide between a "Like" and an
  # "Unlike" button without querying the polymorphic association twice.
  def likes_count(record)
    record.likes_count
  end

  def current_user_like(record)
    return nil unless current_user
    record.likes.find { |like| like.user_id == current_user.id }
  end

  # Same shape as current_user_like above, for posts#show's giveaway
  # section - whether the current visitor already holds a claim decides
  # between showing a "claim a slot" button and a "you already claimed
  # one" notice (see Post#giveaway?/#giveaway_sold_out? for the two other
  # states that section can be in).
  def current_user_claim(post)
    return nil unless current_user
    post.claims.find { |claim| claim.user_id == current_user.id }
  end

  # Display label for the post a comment hangs off of, robust to the post
  # being trashed independently of the comment itself (its own trash/restore
  # cycle - see Post#acts_as_paranoid). Reaches past the default paranoid
  # scope (Post.with_deleted) because a plain Comment#post/Post.find would
  # raise Prism::Orm::RecordNotFound instead of returning the trashed row.
  # Shared by CommentsController#trash and AccountController#comments - both
  # list comments detached from their normal post-scoped page, where a
  # comment can legitimately outlive its post being in the trash.
  def comment_post_label(comment)
    post = comment_post(comment)
    return t('comments.orphaned_post') if post.nil?
    post.deleted? ? t('comments.post_also_trashed', title: post.title) : post.title
  end

  def comment_post_linkable?(comment)
    post = comment_post(comment)
    post && !post.deleted?
  end

  # The slug for comment_post_linkable?'s url_for(:post, ...) - only ever
  # called from inside that guard, so the post here is always the live
  # (not-deleted) one, but reuses the same with_deleted lookup/memoization
  # as the other two helpers above rather than assuming that.
  def comment_post_slug(comment)
    comment_post(comment)&.to_param
  end

  private

  # comment_post_label/#comment_post_linkable?/#comment_post_slug all need
  # the SAME with_deleted Post lookup for a given comment - memoized per
  # post_id so a comment list page (moderation/trash/account#comments)
  # costs one query per distinct post, not up to three per comment.
  def comment_post(comment)
    @comment_post_cache ||= {}
    @comment_post_cache.fetch(comment.post_id) { @comment_post_cache[comment.post_id] = Post.with_deleted.find_by(id: comment.post_id) }
  end

  # One-off JSON:API error object (see Prism::Orm::Errors#to_jsonapi) for
  # failures that do not come from a model's own validations, such as a
  # stale optimistic-locking conflict - keeps the wire shape identical to
  # render_errors so a JSON client only has to understand one error format.
  def jsonapi_error(status:, pointer:, title:, detail:)
    { status: status.to_s, source: { pointer: pointer }, title: title, detail: detail }
  end

  # Content-negotiated 404 for a Prism::Orm::RecordNotFound rescue: plain
  # text/HTML for browser requests, a JSON:API error object (via
  # Renderable#render_not_found) for .json ones - the same halt(404, ...)
  # every controller used to call regardless of what the client asked for,
  # which meant a `.json` 404 came back as a bare HTML-ish string instead
  # of an `errors` array a JSON client could actually parse.
  def respond_not_found(detail)
    respond_to do |format|
      format.html { halt(404, detail) }
      format.json { render_not_found(detail) }
    end
  end

  # Sends the visitor back to the post they were looking at either way -
  # whether it was the post itself, one of its comments, or a like on
  # either - instead of a bare 403, so a signed-in user who simply clicked
  # someone else's delete/unlike button lands somewhere useful.
  def forbidden(exception)
    flash[:notice] = t('errors.forbidden')
    redirect url_for(:post, slug: post_slug_for(exception.record))
  end

  # The record a NotAuthorizedError carries is always live (Comment.find/
  # Post.find already hide soft-deleted rows before a policy ever runs),
  # so `record.post` here is a plain association read, not the with_deleted
  # lookup comment_post/#comment_post_label above need for the trash pages.
  def post_slug_for(record)
    case record
    when Comment then record.post.slug
    when Like then post_slug_for(record.likeable)
    else record.to_param
    end
  end
end
