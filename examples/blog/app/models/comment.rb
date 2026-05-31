class Comment < Prism::Orm::Model
  # touch: true keeps Post#updated_at reflecting the most recent comment
  # activity (created, edited, deleted), not just edits to the post itself -
  # shown as "Last activity" on the post list/show pages.
  belongs_to :post, counter_cache: true, touch: true
  belongs_to :user
  has_many :likes, as: :likeable, dependent: :destroy

  # Paranoid so PostsController#restore(recursive: true) can bring a
  # trashed post's comments back along with it - see Post#acts_as_paranoid.
  acts_as_paranoid

  # Every comment starts life pending (column default 0, see the
  # add_status_to_comments migration) so a post's author gets a chance to
  # approve or reject it before strangers can read it - see
  # CommentsController#approve/#reject and the `visible_to` scope below.
  enum :status, { pending: 0, approved: 1, rejected: 2 }

  # Who gets to see a comment depends on who's asking, not just its status:
  # everyone sees approved comments, the post's author (the moderator) sees
  # everything on their own post regardless of status, and a signed-in
  # commenter always sees their own comment even while it's still pending.
  # `self` inside the block is whatever relation this scope was chained
  # onto (e.g. already narrowed to one post's comments by `post.comments`),
  # so `approved`/`where` compose with that instead of re-querying globally.
  scope :visible_to, lambda { |user, post_author_id|
    next self if user && user.id == post_author_id
    next approved if user.nil?
    approved.or(where(user_id: user.id))
  }

  validates :author, presence: true, length: { minimum: 2 }
  validates :body, presence: true
end
