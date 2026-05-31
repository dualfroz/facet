class CommentsController < ApplicationController
  before_action :require_authentication, only: %i[create edit update destroy approve reject trash restore]

  # Comments were previously only ever visible nested inside
  # PostsController#show (whatever fits on that one page). This gives them
  # their own paginated URL, same etag-over-the-page trick as
  # PostsController#index: current_page/total_count catch a comment being
  # added or removed shifting what belongs on this page even when nothing
  # ON this page changed, the id/updated_at pairs catch edits to any of them.
  def index
    post = Post.find_by!(slug: params['post_id'])
    comments = post.comments.includes(:likes).visible_to(current_user, post.user_id)
                    .order(:created_at, :desc).page(params['page']).per(10)
    respond_to do |format|
      format.html do
        fresh_when(etag: [post.id, post.updated_at, current_user&.id, comments.current_page, comments.total_count,
                           comments.to_a.map { |c| [c.id, c.updated_at] }])
        render(:index, locals: { post: post, comments: comments })
      end
      format.json { json(comments.as_json(only: %i[id author body post_id status])) }
    end
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def create
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.new(params.require('comment').permit(:author, :body).to_h
                                 .merge('post_id' => post.id, 'user_id' => current_user.id))

    if comment.save
      respond_to do |format|
        format.html do
          flash[:notice] = t('comments.created_notice')
          redirect url_for(:post, slug: post.to_param)
        end
        format.json { json(comment.as_json(only: %i[id author body post_id status]), 201) }
      end
    else
      respond_to do |format|
        format.html do
          flash[:notice] = comment.errors.full_messages.join(', ')
          redirect url_for(:post, slug: post.to_param)
        end
        format.json { render_errors(comment) }
      end
    end
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def edit
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment, :update?)
    render(:edit, locals: { post: post, comment: comment, errors: [] })
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  # Only the body is editable (author is fixed at creation, same reasoning
  # as PostsController#update not letting the edit form touch cover/user_id)
  # so Comment#saved_changes below can only ever report `body`. `lock_version`
  # rides along the same way it does for Post - the value the edit form was
  # rendered with, checked against the row's actual current version by
  # Comment#save (locking_enabled? auto-detects the column added by the
  # add_lock_version_to_comments migration, no model change needed).
  def update
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment)
    comment.assign(params.require('comment').permit(:body, :lock_version).to_h)

    if comment.save
      changed_fields = comment.saved_changes.keys - ['updated_at', 'lock_version']
      respond_to do |format|
        format.html do
          flash[:notice] = changed_fields.empty? ? t('comments.update_noop_notice') : t('comments.updated_notice', fields: changed_fields.join(', '))
          redirect url_for(:post, slug: post.to_param)
        end
        format.json { json(comment.as_json(only: %i[id author body post_id status])) }
      end
    else
      respond_to do |format|
        format.html do
          status(422)
          render(:edit, locals: { post: post, comment: comment, errors: comment.errors.full_messages })
        end
        format.json { render_errors(comment) }
      end
    end
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  rescue Prism::Orm::StaleObjectError
    respond_to do |format|
      format.html do
        status(409)
        render(:edit, locals: { post: post, comment: Comment.find(params['id']), errors: [t('comments.stale_notice')] })
      end
      format.json do
        json({ errors: [jsonapi_error(status: 409, pointer: '/data/attributes/lock_version',
                                       title: 'is stale', detail: t('comments.stale_notice'))] }, 409)
      end
    end
  end

  def destroy
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment)
    comment.destroy
    broadcast_comment_count(post)
    redirect url_for(:post, slug: post.to_param)
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  # approved!/rejected! come straight from Comment's `enum :status` (see
  # the model), same "find, authorize like an edit, flip the status" shape
  # as PostsController#publish/#unpublish. CommentPolicy#approve?/#reject?
  # check the POST's owner, not the comment's - moderation is the post
  # author's call, not the commenter's.
  def approve
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment)
    comment.approved!
    broadcast_comment_count(post)
    flash[:notice] = t('comments.approved_notice')
    redirect url_for(:post, slug: post.to_param)
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  def reject
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment)
    comment.rejected!
    broadcast_comment_count(post)
    flash[:notice] = t('comments.rejected_notice')
    redirect url_for(:post, slug: post.to_param)
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  # Every comment a signed-in user has removed, across every post they ever
  # commented on - a flat, top-level page (see the routes in app.rb), not
  # nested under any one post, since a commenter's trash is not the same
  # thing as PostsController#trash and does not depend on whether the post
  # itself is trashed (Comment#acts_as_paranoid keeps its own deleted_at,
  # independent of its post's - see the model). Comment.only_deleted (see
  # acts_as_paranoid) is the one place in this controller that deliberately
  # reaches past the default paranoid scope every other action relies on to
  # hide soft-deleted rows.
  def trash
    comments = Comment.only_deleted.where(user_id: current_user.id).order(:updated_at, :desc).to_a
    render(:trash, locals: { comments: comments, notice: flash[:notice] })
  end

  # find_by! against only_deleted (not the default Comment.find, which
  # hides trashed rows) - restoring a comment that was never trashed, or
  # someone else's, both come back as the same 404 a stranger's comment id
  # would. recursive: true brings back this comment's own likes if they
  # were soft-deleted alongside it by the dependent: :destroy cascade on
  # Comment#destroy (Like is paranoid too - see cascade_restore_dependent_
  # associations); it does not touch the comment's post either way.
  def restore
    comment = Comment.only_deleted.find_by!(id: params['id'].to_i)
    authorize(comment, :restore?)
    comment.restore(recursive: true)
    flash[:notice] = t('comments.restored_notice')
    redirect url_for(:trash_comments)
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  private

  # Pushed to every open posts#show tab's PostActivityChannel subscription
  # (see the model) - approve/reject/destroy are the only three actions
  # that can change how many APPROVED comments a post has (create cannot,
  # every comment starts life pending), so this is called from exactly
  # those three, never from create/update.
  def broadcast_comment_count(post)
    # stream_for/post_id_from (see the channel) treat this as an opaque
    # string key, not a real id - post.to_param (the slug) so the stream a
    # client subscribes to via GET /cable?post_id=<slug> (posts/show.erb
    # has no inline subscriber script yet, but blog_websocket_demo.rb
    # subscribes using the same slug it got from the post's own URL)
    # actually matches what gets broadcast to here.
    PostActivityChannel.hub.broadcast(
      PostActivityChannel.stream_for(post.to_param),
      event: 'comment_count', post_id: post.to_param, count: post.comments.approved.count
    )
  end
end
