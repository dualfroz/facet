class SessionController < ApplicationController
  def new
    render(:new, locals: { errors: [] })
  end

  def create
    credentials = params.require('user').permit(:email, :password, :remember_me).to_h
    user = User.find_by(email: credentials['email'])

    if user && user.authenticate(credentials['password'])
      sign_in(user, remember: credentials['remember_me'] == '1')
      respond_to do |format|
        format.html do
          flash[:notice] = t('sessions.signed_in_notice')
          redirect after_authentication_url
        end
        format.json { json(user.as_json(methods: [:email])) }
      end
    else
      respond_to do |format|
        format.html do
          status(422)
          render(:new, locals: { errors: [t('sessions.invalid_credentials')] })
        end
        # 401, not 422 like the HTML branch above: there is no resource
        # here whose validation failed (no User object at all when the
        # email does not match anyone), just a rejected authentication
        # attempt - the JSON:API status a client should actually branch on.
        format.json do
          json({ errors: [jsonapi_error(status: 401, pointer: '/data/attributes/password',
                                         title: 'invalid credentials', detail: t('sessions.invalid_credentials'))] }, 401)
        end
      end
    end
  end

  def destroy
    sign_out
    respond_to do |format|
      format.html do
        flash[:notice] = t('sessions.signed_out_notice')
        redirect url_for(:root)
      end
      format.json { json({ message: t('sessions.signed_out_notice') }) }
    end
  end
end
