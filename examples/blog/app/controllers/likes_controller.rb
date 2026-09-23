class LikesController < ApplicationController
  before_action :require_authentication

  LIKEABLE_TYPES = { 'Post' => Post, 'Comment' => Comment }.freeze

  def create
    likeable = find_likeable!
    Like.create(user_id: current_user.id, likeable_id: likeable.id, likeable_type: likeable.class.name)
    redirect url_for(:post, slug: post_slug_for(likeable))
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('likes.not_found'))
  end

  def destroy
    like = Like.find(params['id'])
    authorize(like)
    likeable = like.likeable
    like.really_destroy!
    redirect url_for(:post, slug: post_slug_for(likeable))
  rescue Facet::Orm::RecordNotFound
    respond_not_found(t('likes.not_found'))
  end

  private

  def find_likeable!
    klass = LIKEABLE_TYPES.fetch(params['likeable_type']) { raise Facet::Orm::RecordNotFound }
    klass.find(params['likeable_id'])
  end
end
