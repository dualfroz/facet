class AccountController < ApplicationController
  before_action :require_authentication

  def edit
    render(:edit, locals: { user: current_user, errors: [] })
  end

  # current_user.comments is a plain `Comment.where(user_id: id)` (Associable
  # #has_many, no through:/as:) - a single HashNode equality answerable by
  # Store#lookup_by_index on comments.user_id the moment that index exists
  # (see db/migrate/20260907000008_add_index_on_comments_user_id.rb), unlike
  # every other approved/visible_to call site in this app: those all chain
  # off post.comments first, so their equalities hash already carries
  # post_id too and the pre-existing post_id index wins the tie - this is
  # the one place comments.user_id gets to be the index actually picked.
  def comments
    comments = current_user.comments.order(:created_at, :desc).page(params['page']).per(10)
    fresh_when(etag: [current_user.id, comments.current_page, comments.total_count,
                       comments.to_a.map { |c| [c.id, c.updated_at] }])
    render(:comments, locals: { comments: comments })
  end

  # A post's comments start life pending (Comment's `enum :status`) so its
  # author can approve/reject before strangers see them - but the only way
  # to act on that today is opening each post's own page one at a time
  # (posts/_comment.erb's approve/reject buttons). This gathers every
  # pending comment across EVERY post the current user owns onto one page,
  # the same "flatten across posts" shape as #comments above but filtered
  # to pending instead of to authorship. Two index-backed queries, not one
  # scan each: current_user.posts (posts.user_id, see the migration
  # referenced on User) narrows to this user's own post ids first, then
  # Comment.pending.where(post_id: ...) reuses the existing comments.post_id
  # index's IN-list lookup (Store#lookup_by_index_in) across all of them at
  # once, with the leftover `status` equality filtered from that already-
  # small candidate set in memory - see ConditionNode#indexed_candidates.
  def moderation
    post_ids = current_user.posts.pluck(:id)
    comments = Comment.pending.where(post_id: post_ids)
                       .order(:created_at, :desc).page(params['page']).per(10)
    fresh_when(etag: [current_user.id, comments.current_page, comments.total_count,
                       comments.to_a.map { |c| [c.id, c.updated_at] }])
    render(:moderation, locals: { comments: comments })
  end

  # User#email is `encrypts :email, deterministic: true` (see the model) -
  # this is the one place in the whole demo where a user's own encrypted
  # attribute is genuinely rewritten through a real HTTP request instead of
  # only being set once at sign-up, which is exactly what forces a fresh
  # `Encryption.encrypt` call under the CURRENTLY configured primary key.
  # That makes this action the natural vehicle for exercising key rotation
  # end to end (see rotation_worker.rb): a user who visits this page after
  # the app's encryption secret has rotated and re-saves their (possibly
  # unchanged) email migrates that one row onto the new key for free,
  # exactly the way Prism::Orm::Encryption's own comments describe.
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
