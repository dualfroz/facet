class Comment < Facet::Orm::Model
  belongs_to :post, counter_cache: true, touch: true
  belongs_to :user
  has_many :likes, as: :likeable, dependent: :destroy

  acts_as_paranoid

  enum :status, { pending: 0, approved: 1, rejected: 2 }

  scope :visible_to, lambda { |user, post_author_id|
    next self if user && user.id == post_author_id
    next approved if user.nil?
    approved.or(where(user_id: user.id))
  }

  validates :author, presence: true, length: { minimum: 2 }
  validates :body, presence: true
end
