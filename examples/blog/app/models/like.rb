class Like < Prism::Orm::Model
  belongs_to :user
  belongs_to :likeable, polymorphic: true, counter_cache: true

  # Same reasoning as Comment#acts_as_paranoid - a trashed post's likes (and
  # a trashed post's comments' own likes) come back with it on restore.
  acts_as_paranoid

  validates :user_id, presence: true, uniqueness: { scope: %i[likeable_id likeable_type] }
end
