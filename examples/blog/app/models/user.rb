class User < Prism::Orm::Model
  has_secure_password
  has_many :login_sessions, dependent: :destroy
  # No dependent: - there is no user-deletion flow, so nothing ever destroys
  # the owner side of this association; used read-only by AccountController#
  # comments ("my comments" across every post, indexed on comments.user_id).
  has_many :comments
  # Same read-only shape as :comments above, used only by AccountController
  # #moderation to find which posts belong to the current user before
  # looking up pending comments on them (indexed on posts.user_id - see
  # db/migrate/20260907000009_add_index_on_posts_user_id.rb).
  has_many :posts

  # email is PII, so it is encrypted at rest (deterministic: true so
  # find_by(email:)/uniqueness can still match on plaintext - see
  # Prism::Orm::Encryption). Validators read the attribute's own reader
  # method (Validatable#public_send), so they see the decrypted plaintext
  # here exactly like they would for a plain column.
  encrypts :email, deterministic: true
  validates :email, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }

  # Backs PasswordResetsController's forgot-password flow (session 99's
  # Prism::Orm::TokenFor). The fingerprint block snapshots password_digest
  # at token-mint time, so a token becomes worthless the moment ANY save
  # changes the digest - the successful reset that consumes it, but also a
  # second concurrent reset request or a manual password change elsewhere -
  # without a separate "used" column or token table to track that by hand.
  generates_token_for(:password_reset, expires_in: 900) { password_digest }

  # Backs EmailConfirmationsController. Fingerprinted on email (not
  # password_digest like the reset token above, and not confirmed_at
  # either) - so a link minted for one address stops verifying the moment
  # that address changes (see reset_confirmation_if_email_changed below),
  # but stays valid across repeat visits: confirming twice with the same
  # link is harmless (#show is a no-op once confirmed_at is already set),
  # unlike a password reset token, which self-invalidates on first use
  # because using it always changes the fingerprint it was minted under.
  # No expires_in - an email that sits unread for a week should still
  # confirm when it is finally opened, unlike a reset link nobody would
  # still want to click that late.
  generates_token_for(:email_confirmation) { email }

  def confirmed?
    !confirmed_at.nil?
  end

  # Devise-style "reconfirmable": changing to a new address un-confirms the
  # account rather than silently keeping the old confirmation around for an
  # email nobody has proven they control yet. Only fires on an update (see
  # `before_update`, not `before_save`) - on #create confirmed_at is already
  # nil from the migration's default, so there is nothing to reset.
  before_update :reset_confirmation_if_email_changed

  # Same after_commit(on: :create) shape as Post's new-post notification -
  # queued only once the sign-up has actually survived to disk, so a
  # rolled-back create (e.g. a validation failure surfacing after this
  # hook in some future callback) never sends a welcome/confirmation email
  # for an account that does not exist.
  after_commit(on: :create) { NotificationMailer.welcome(id).deliver_later }
  after_commit(on: :create) do
    NotificationMailer.confirmation_instructions(id, generate_token_for(:email_confirmation)).deliver_later
  end

  private

  def reset_confirmation_if_email_changed
    self.confirmed_at = nil if attribute_changed?('email')
  end
end
