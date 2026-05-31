class EmailConfirmationsController < ApplicationController
  # Resend form - for whoever's original confirmation link expired out of
  # their inbox, landed in spam, or was simply never sent because a typo in
  # the signup form pointed User#generates_token_for at an address they
  # don't control.
  def new
    render(:new)
  end

  # Same enumeration-safe shape as PasswordResetsController#create: the
  # response never reveals whether the address has an account here, or
  # whether it is already confirmed - branching on either would turn this
  # form into a one-guess-at-a-time oracle for both facts.
  def create
    email = params.require('email_confirmation').permit(:email).to_h['email']
    user = User.find_by(email: email)
    if user && !user.confirmed?
      NotificationMailer.confirmation_instructions(user.id, user.generate_token_for(:email_confirmation)).deliver_later
    end
    flash[:notice] = t('email_confirmations.instructions_sent_notice')
    redirect url_for(:new_session)
  end

  # Reached via a plain GET from the link in the confirmation email, like
  # PasswordResetsController#edit - safe to expose over GET (and to visit
  # more than once) because, unlike a password reset, confirming does not
  # hand the visitor anything sensitive and does not itself change the
  # fingerprint (email) the token was minted under, so a bookmarked or
  # double-clicked link keeps working instead of dying after first use.
  def show
    user = User.find_by_token_for(:email_confirmation, params['token'])
    unless user
      flash[:notice] = t('email_confirmations.invalid_token_notice')
      redirect url_for(:new_email_confirmation)
      return
    end

    user.update!(confirmed_at: Time.now.utc) unless user.confirmed?
    flash[:notice] = t('email_confirmations.confirmed_notice')
    redirect url_for(:root)
  end
end
