class Claim < Prism::Orm::Model
  # counter_cache keeps Post#claims_count (and therefore
  # Post#giveaway_remaining/#giveaway_sold_out?) O(1) to read - the whole
  # point of ClaimsController#create locking the post first is to make that
  # read-then-decide safe under concurrency, which would be undermined if
  # the read itself required walking every Claim row instead.
  belongs_to :post, counter_cache: true
  belongs_to :user

  # Not a user-facing "unclaim" - a claim has no destroy action anywhere in
  # this app (see ClaimsController, create-only). Paranoid purely so
  # Post#acts_as_paranoid's `dependent: :destroy` cascade (see the model)
  # soft-deletes a giveaway's claims along with a trashed post instead of
  # erasing the record of who already won a slot, and #restore(recursive:
  # true) brings them back - same shape as Comment/Like.
  acts_as_paranoid

  # One claim per user per post - see the unique index on [:post_id,
  # :user_id] in the create_claims migration for the same rule enforced at
  # the Store level too, inside whatever transaction the insert runs in.
  validates :user_id, presence: true, uniqueness: { scope: :post_id }
end
