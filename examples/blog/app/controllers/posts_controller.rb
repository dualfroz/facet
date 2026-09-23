require 'csv'
require 'fileutils'

class PostsController < ApplicationController
  before_action :require_authentication,
                only: %i[create edit update destroy preview publish unpublish trash restore import move_up move_down]

  def index
    days = params['days'].to_i
    featured_only = params['featured'] && Facet::Orm::TypeCasting.cast(:boolean, params['featured'])
    scope = Post.published
    scope = scope.created_within(days) if days.positive?
    scope = scope.featured if featured_only
    posts = featured_only ? scope.order(:position, :asc).page(params['page']).per(5)
                           : scope.order(:created_at, :desc).page(params['page']).per(5)
    respond_to do |format|
      format.html do
        notice = flash[:notice]
        fresh_when(etag: [posts.current_page, posts.total_count,
                           posts.to_a.map { |p| [p.id, p.updated_at, p.position] }, notice,
                           current_user&.id, days, featured_only])
        render(:index, locals: { posts: posts, new_post: Post.new, notice: notice, errors: [], days: days,
                                  featured_only: featured_only })
      end
      format.json do
        json(posts.as_json(only: %i[id slug title body cover]))
      end
    end
  end

  def show
    post = Post.find_by!(slug: params['slug'])
    comments = post.comments.includes(:likes).visible_to(current_user, post.user_id).order(:created_at, :desc).to_a
    notice = flash[:notice]
    fresh_when(etag: [post.id, post.updated_at, post.claims_count, current_user&.id,
                      comments.map { |c| [c.id, c.updated_at] }, notice])
    render(:show, locals: { post: post, comments: comments, new_comment: Comment.new, notice: notice })
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def export
    days = params['days'].to_i
    scope = Post.published
    scope = scope.created_within(days) if days.positive?
    headers('Content-Type' => 'text/csv')
    stream do |out|
      out.write(CSV.generate_line(%w[id title created_at]))
      scope.order(:created_at, :desc).find_each do |post|
        out.write(CSV.generate_line([post.id, post.title, post.created_at.utc.iso8601]))
      end
    end
  end

  def import
    file = params['file']
    unless file.is_a?(Facet::UploadedFile) && !file.original_filename.to_s.empty?
      flash[:notice] = t('posts.import_missing_file')
      redirect url_for(:posts)
      return
    end
    result = Post.import_csv(file.read, author: current_user)
    flash[:notice] = t('posts.import_notice', imported: result.imported.size, skipped: result.skipped.size)
    redirect url_for(:posts)
  end

  def create
    attrs = params.require('post').permit(:title, :body, :featured, :giveaway_slots).to_h
    attrs['status'] = :published
    attrs['cover'] = store_cover(params['post']['cover'])
    attrs['user_id'] = current_user.id
    post = Post.create_with_unique_slug(attrs)

    if post.persisted?
      respond_to do |format|
        format.html do
          flash[:notice] = t('posts.created_notice', id: post.id)
          redirect url_for(:post, slug: post.to_param)
        end
        format.json { json(post.as_json(only: %i[id slug title body cover]), 201) }
      end
    else
      respond_to do |format|
        format.html do
          status(422)
          render(:index, locals: { posts: Post.published.order(:created_at, :desc).page(1).per(5), new_post: post, notice: nil,
                                    errors: post.errors.full_messages, days: 0, featured_only: false })
        end
        format.json { render_errors(post) }
      end
    end
  end

  def edit
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    render(:edit, locals: { post: post, errors: [] })
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def preview
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    attempted = params.require('post').permit(:title, :body, :lock_version).to_h
    post.assign(attempted)
    post.valid?
    diff = post.changes.reject { |field, _| field == 'lock_version' }
    errors = post.errors.full_messages
    post.restore_attributes
    render(:preview, locals: { post: post, diff: diff, errors: errors, attempted: attempted })
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def update
    post = Post.find_by!(slug: params['slug'])
    authorize(post)
    permitted = params.require('post').permit(
      :title, :body, :featured, :giveaway_slots, :lock_version, comments_attributes: %i[id body _destroy]
    ).to_h
    post.assign(permitted)

    if post.save
      changed_fields = post.saved_changes.keys - ['updated_at', 'lock_version']
      respond_to do |format|
        format.html do
          flash[:notice] = changed_fields.empty? ? t('posts.update_noop_notice') : t('posts.updated_notice', fields: changed_fields.join(', '))
          redirect url_for(:post, slug: post.to_param)
        end
        format.json { json(post.as_json(only: %i[id slug title body cover])) }
      end
    else
      respond_to do |format|
        format.html do
          status(422)
          render(:edit, locals: { post: post, errors: post.errors.full_messages })
        end
        format.json { render_errors(post) }
      end
    end
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  rescue Facet::Orm::StaleObjectError
    respond_to do |format|
      format.html do
        status(409)
        render(:edit, locals: { post: Post.find_by!(slug: params['slug']), errors: [t('posts.stale_notice')] })
      end
      format.json do
        json({ errors: [jsonapi_error(status: 409, pointer: '/data/attributes/lock_version',
                                       title: 'is stale', detail: t('posts.stale_notice'))] }, 409)
      end
    end
  end

  def destroy
    post = Post.find_by!(slug: params['slug'])
    authorize(post)
    post.destroy
    flash[:notice] = t('posts.deleted_notice', id: post.id)
    redirect url_for(:posts)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def trash
    posts = Post.only_deleted.where(user_id: current_user.id).order(:updated_at, :desc).to_a
    render(:trash, locals: { posts: posts, notice: flash[:notice] })
  end

  def restore
    post = Post.only_deleted.find_by!(slug: params['slug'])
    authorize(post, :restore?)
    post.restore(recursive: true)
    flash[:notice] = t('posts.restored_notice', id: post.id)
    redirect url_for(:trash_posts)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def publish
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    post.published!
    flash[:notice] = t('posts.published_notice', id: post.id)
    redirect url_for(:post, slug: post.to_param)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def unpublish
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    post.draft!
    flash[:notice] = t('posts.unpublished_notice', id: post.id)
    redirect url_for(:post, slug: post.to_param)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def move_up
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    post.move_higher
    redirect "#{url_for(:posts)}?featured=1"
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  def move_down
    post = Post.find_by!(slug: params['slug'])
    authorize(post, :update?)
    post.move_lower
    redirect "#{url_for(:posts)}?featured=1"
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end

  private

  def store_cover(upload)
    return nil unless upload.is_a?(Facet::UploadedFile)
    return nil if upload.original_filename.to_s.empty?

    uploads_dir = File.join(APP_ROOT, 'public', 'uploads')
    FileUtils.mkdir_p(uploads_dir)
    safe_name = "#{Time.now.strftime('%Y%m%d%H%M%S')}-#{upload.original_filename.gsub(/[^a-zA-Z0-9_.-]/, '_')}"
    File.binwrite(File.join(uploads_dir, safe_name), upload.read)
    safe_name
  end
end
