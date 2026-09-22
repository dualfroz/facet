class EmailConfirmationsController < ApplicationController
  def new
    render(:new)
  end

  def create
    email = params.require('email_confirmation').permit(:email).to_h['email']
    user = User.find_by(email: email)
    if user && !user.confirmed?
      NotificationMailer.confirmation_instructions(user.id, user.generate_token_for(:email_confirmation)).deliver_later
    end
    flash[:notice] = t('email_confirmations.instructions_sent_notice')
    redirect url_for(:new_session)
  end

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
