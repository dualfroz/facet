class LikesController < ApplicationController
  before_action :require_authentication

  # Only Post/Comment may be liked - likeable_type otherwise rides in fully
  # client-controlled request params, so without this whitelist a crafted
  # request could aim a Like at an arbitrary model by name (e.g. User) and
  # #likeable would happily resolve it.
  LIKEABLE_TYPES = { 'Post' => Post, 'Comment' => Comment }.freeze

  def create
    likeable = find_likeable!
    Like.create(user_id: current_user.id, likeable_id: likeable.id, likeable_type: likeable.class.name)
    redirect url_for(:post, slug: post_slug_for(likeable))
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('likes.not_found'))
  end

  def destroy
    like = Like.find(params['id'])
    authorize(like)
    likeable = like.likeable
    # really_destroy!, not the paranoid-aware plain #destroy - unliking is
    # a permanent, unremarkable action with no "restore my unlike" concept
    # in this app, unlike Post.acts_as_paranoid's actual trash/restore UI.
    # Left as a soft delete, every unlike/relike cycle would pile up a
    # dead Like row forever (uniqueness scope only sees live rows, so
    # nothing would ever stop a visitor from accumulating one per cycle),
    # and a post's dependent: :destroy cascade would then have no way to
    # tell "trashed along with its post" apart from "explicitly unliked
    # ages ago" when a restore brings the post's likes back.
    like.really_destroy!
    redirect url_for(:post, slug: post_slug_for(likeable))
  rescue Prism::Orm::RecordNotFound
    respond_not_found(t('likes.not_found'))
  end

  private

  def find_likeable!
    klass = LIKEABLE_TYPES.fetch(params['likeable_type']) { raise Prism::Orm::RecordNotFound }
    klass.find(params['likeable_id'])
  end
end
