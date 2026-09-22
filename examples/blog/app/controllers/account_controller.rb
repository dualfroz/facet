class AccountController < ApplicationController
  before_action :require_authentication

  def edit
    render(:edit, locals: { user: current_user, errors: [] })
  end

  def comments
    comments = current_user.comments.order(:created_at, :desc).page(params['page']).per(10)
    fresh_when(etag: [current_user.id, comments.current_page, comments.total_count,
                       comments.to_a.map { |c| [c.id, c.updated_at] }])
    render(:comments, locals: { comments: comments })
  end

  def moderation
    post_ids = current_user.posts.pluck(:id)
    comments = Comment.pending.where(post_id: post_ids)
                       .order(:created_at, :desc).page(params['page']).per(10)
    fresh_when(etag: [current_user.id, comments.current_page, comments.total_count,
                       comments.to_a.map { |c| [c.id, c.updated_at] }])
    render(:moderation, locals: { comments: comments })
  end

  def update
    attrs = params.require('user').permit(:email).to_h
    current_user.assign(attrs)

    if current_user.save
      changed_fields = current_user.saved_changes.keys - ['updated_at']
      flash[:notice] = changed_fields.empty? ? t('account.update_noop_notice') : t('account.updated_notice', fields: changed_fields.join(', '))
      redirect url_for(:edit_account)
    else
      status(422)
      render(:edit, locals: { user: current_user, errors: current_user.errors.full_messages })
    end
  end
end
