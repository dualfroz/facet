class PasswordResetsController < ApplicationController
  def new
    render(:new)
  end

  def create
    email = params.require('password_reset').permit(:email).to_h['email']
    user = User.find_by(email: email)
    if user
      token = user.generate_token_for(:password_reset)
      NotificationMailer.password_reset(user.id, token).deliver_later
    end
    flash[:notice] = t('password_resets.instructions_sent_notice')
    redirect url_for(:new_session)
  end

  def edit
    user = User.find_by_token_for(:password_reset, params['token'])
    if user
      render(:edit, locals: { token: params['token'], errors: [] })
    else
      flash[:notice] = t('password_resets.invalid_token_notice')
      redirect url_for(:new_password_reset)
    end
  end

  def update
    user = User.find_by_token_for(:password_reset, params['token'])
    unless user
      flash[:notice] = t('password_resets.invalid_token_notice')
      redirect url_for(:new_password_reset)
      return
    end

    attrs = params.require('password_reset').permit(:password, :password_confirmation).to_h
    user.password = attrs['password']
    user.password_confirmation = attrs['password_confirmation']

    if user.save
      flash[:notice] = t('password_resets.reset_notice')
      redirect url_for(:new_session)
    else
      status(422)
      render(:edit, locals: { token: params['token'], errors: user.errors.full_messages })
    end
  end
end
