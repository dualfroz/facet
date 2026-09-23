class UsersController < ApplicationController
  def new
    render(:new, locals: { user: User.new, errors: [] })
  end

  def create
    attrs = params.require('user').permit(:email, :password, :password_confirmation).to_h
    user = User.new(attrs)

    if user.save
      sign_in(user)
      respond_to do |format|
        format.html do
          flash[:notice] = t('users.signed_up_notice')
          redirect url_for(:root)
        end
        format.json { json(user.as_json(methods: [:email]), 201) }
      end
    else
      respond_to do |format|
        format.html do
          status(422)
          render(:new, locals: { user: user, errors: user.errors.full_messages })
        end
        format.json { render_errors(user) }
      end
    end
  rescue Facet::Orm::Store::UniqueConstraintViolation
    respond_to do |format|
      format.html do
        status(422)
        render(:new, locals: { user: user, errors: [t('users.email_taken_notice')] })
      end
      format.json do
        json({ errors: [jsonapi_error(status: 422, pointer: '/data/attributes/email',
                                       title: 'is taken', detail: t('users.email_taken_notice'))] }, 422)
      end
    end
  end
end
