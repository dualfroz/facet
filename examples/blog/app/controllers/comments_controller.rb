class CommentsController < ApplicationController
  before_action :require_authentication, only: %i[create edit update destroy approve reject trash restore]

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
  rescue Facet::Orm::RecordNotFound
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
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def edit
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment, :update?)
    render(:edit, locals: { post: post, comment: comment, errors: [] })
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

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
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  rescue Facet::Orm::StaleObjectError
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
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def approve
    post = Post.find_by!(slug: params['post_id'])
    comment = Comment.find(params['id'])
    authorize(comment)
    comment.approved!
    broadcast_comment_count(post)
    flash[:notice] = t('comments.approved_notice')
    redirect url_for(:post, slug: post.to_param)
  rescue Facet::Orm::RecordNotFound
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
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  def trash
    comments = Comment.only_deleted.where(user_id: current_user.id).order(:updated_at, :desc).to_a
    render(:trash, locals: { comments: comments, notice: flash[:notice] })
  end

  def restore
    comment = Comment.only_deleted.find_by!(id: params['id'].to_i)
    authorize(comment, :restore?)
    comment.restore(recursive: true)
    flash[:notice] = t('comments.restored_notice')
    redirect url_for(:trash_comments)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('comments.not_found'))
  end

  private

  def broadcast_comment_count(post)
    PostActivityChannel.hub.broadcast(
      PostActivityChannel.stream_for(post.to_param),
      event: 'comment_count', post_id: post.to_param, count: post.comments.approved.count
    )
  end
end
