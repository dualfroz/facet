class Claim < Facet::Orm::Model
  belongs_to :post, counter_cache: true
  belongs_to :user

  acts_as_paranoid

  validates :user_id, presence: true, uniqueness: { scope: :post_id }
end
