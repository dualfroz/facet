class Like < Facet::Orm::Model
  belongs_to :user
  belongs_to :likeable, polymorphic: true, counter_cache: true

  acts_as_paranoid

  validates :user_id, presence: true, uniqueness: { scope: %i[likeable_id likeable_type] }
end
