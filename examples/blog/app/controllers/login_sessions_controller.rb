class LoginSessionsController < ApplicationController
  before_action :require_authentication

  def index
    render(:index, locals: {
             current_session: current_login_session,
             other_sessions: other_login_sessions.order(:created_at, :desc).to_a,
             notice: flash[:notice]
           })
  end

  def destroy
    flash[:notice] = if revoke_login_session!(params['id'])
                        t('login_sessions.revoked_notice')
                      else
                        t('login_sessions.not_found')
                      end
    redirect url_for(:login_sessions)
  end

  def sign_out_others
    sign_out_all_other_sessions
    flash[:notice] = t('login_sessions.signed_out_others_notice')
    redirect url_for(:login_sessions)
  end

  def device_detail_for(login_session)
    t('login_sessions.device_detail',
      user_agent: login_session.user_agent || t('login_sessions.unknown_user_agent'),
      ip_address: login_session.ip_address || t('login_sessions.unknown_ip_address'))
  end
end
