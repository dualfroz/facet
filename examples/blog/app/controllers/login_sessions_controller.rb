class LoginSessionsController < ApplicationController
  before_action :require_authentication

  # "Your devices": every remembered browser for the signed-in user, with
  # whichever one answered THIS request called out separately so the view
  # can label it "this device" instead of just another row in the list.
  def index
    render(:index, locals: {
             current_session: current_login_session,
             other_sessions: other_login_sessions.order(:created_at, :desc).to_a,
             notice: flash[:notice]
           })
  end

  # Revokes one remembered browser. revoke_login_session! already checks
  # ownership (a foreign id, or one belonging to someone else, is a no-op),
  # so there is nothing else to authorize here.
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

  # "TestBrowser/1.0 from 203.0.113.7" - falls back to the generic
  # "unknown browser"/"unknown address" strings for rows remembered before
  # this metadata started being captured (a plain nil column, not a bug).
  def device_detail_for(login_session)
    t('login_sessions.device_detail',
      user_agent: login_session.user_agent || t('login_sessions.unknown_user_agent'),
      ip_address: login_session.ip_address || t('login_sessions.unknown_ip_address'))
  end
end
