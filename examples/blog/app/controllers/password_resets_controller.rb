class PasswordResetsController < ApplicationController
  def new
    render(:new)
  end

  # Always shows the SAME generic "check your email" notice whether or not
  # the address belongs to an account - branching the response on
  # User.find_by(email:) here would turn this form into an email-enumeration
  # oracle one guess at a time, the same concern app.rb's signups/ip
  # throttle exists for one step earlier in the account lifecycle (and this
  # action gets its own password_resets/ip throttle below for the same
  # reason: even a constant-response endpoint still leaks timing/rate
  # information if it can be hit without limit).
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

  # find_by_token_for's fingerprint block (see User#generates_token_for)
  # snapshots password_digest at #new/#create time - so the very save
  # below that sets the new password also produces a new digest, which
  # means the SAME token this action just accepted can never verify again
  # afterwards. A stolen-but-unused link still dies once its owner resets
  # through it; there is no separate "used" flag or token table to keep
  # that guarantee true.
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
