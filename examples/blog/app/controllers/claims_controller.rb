class ClaimsController < ApplicationController
  before_action :require_authentication

  # Giveaway slots are a hard cap that has to hold under real concurrency,
  # not just in whichever request happens to run first: two visitors
  # racing the same "claim a slot" button must never both walk away
  # believing they won one of the last N copies. Post#with_lock
  # (Prism::Orm::Pessimistic, wired into every Model since session ~99)
  # holds Store's real cross-process file lock for this entire
  # reload-check-decide-write critical section, so a concurrent request -
  # even from a completely separate `Prism::Server` OS process sharing this
  # same database file, not just another thread of this one, see
  # blog_giveaway_demo.rb/blog_giveaway_worker.rb - blocks on its own
  # transaction until this one has already committed, instead of both
  # reading the same not-yet-updated claims_count and both deciding a slot
  # was still free.
  def create
    post = Post.find_by!(slug: params['post_id'])
    raise Prism::Orm::RecordNotFound unless post.giveaway?

    outcome = nil
    post.with_lock do |locked_post|
      if locked_post.giveaway_sold_out?
        outcome = :sold_out
      else
        claim = Claim.new(post_id: locked_post.id, user_id: current_user.id)
        # The only realistic validation failure left once
        # giveaway_sold_out? has already passed is the uniqueness scope -
        # the same visitor double-submitting the claim form (e.g. a
        # doubled-click, or hitting back and resubmitting).
        outcome = claim.save ? :claimed : :already_claimed
      end
    end

    flash[:notice] = t("claims.#{outcome}_notice")
    redirect url_for(:post, slug: post.to_param)
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end
end
