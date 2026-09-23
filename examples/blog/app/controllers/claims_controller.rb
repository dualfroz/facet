class ClaimsController < ApplicationController
  before_action :require_authentication

  def create
    post = Post.find_by!(slug: params['post_id'])
    raise Facet::Orm::RecordNotFound unless post.giveaway?

    outcome = nil
    post.with_lock do |locked_post|
      if locked_post.giveaway_sold_out?
        outcome = :sold_out
      else
        claim = Claim.new(post_id: locked_post.id, user_id: current_user.id)
        outcome = claim.save ? :claimed : :already_claimed
      end
    end

    flash[:notice] = t("claims.#{outcome}_notice")
    redirect url_for(:post, slug: post.to_param)
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('posts.not_found'))
  end
end
