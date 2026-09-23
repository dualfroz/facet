class User < Facet::Orm::Model
  has_secure_password
  has_many :login_sessions, dependent: :destroy
  has_many :comments
  has_many :posts

  encrypts :email, deterministic: true
  validates :email, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }

  generates_token_for(:password_reset, expires_in: 900) { password_digest }

  generates_token_for(:email_confirmation) { email }

  def confirmed?
    !confirmed_at.nil?
  end

  before_update :reset_confirmation_if_email_changed

  after_commit(on: :create) { NotificationMailer.welcome(id).deliver_later }
  after_commit(on: :create) do
    NotificationMailer.confirmation_instructions(id, generate_token_for(:email_confirmation)).deliver_later
  end

  private

  def reset_confirmation_if_email_changed
    self.confirmed_at = nil if attribute_changed?('email')
  end
end
