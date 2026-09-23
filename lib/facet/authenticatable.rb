module Facet
  module Authenticatable
    REMEMBER_COOKIE_MAX_AGE = 20 * 365 * 24 * 60 * 60

    REMEMBER_SESSION_COOKIE = :remember_session_token

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      attr_writer :authenticatable_model, :authenticatable_session_key, :unauthenticated_redirect_path,
                  :authenticatable_remember_cookie, :authenticatable_remember_sessions_model,
                  :authenticatable_remember_sessions_foreign_key, :authenticatable_max_remember_sessions

      %i[authenticatable_model authenticatable_session_key unauthenticated_redirect_path
         authenticatable_remember_cookie authenticatable_remember_sessions_model
         authenticatable_remember_sessions_foreign_key authenticatable_max_remember_sessions].each do |setting|
        define_method(setting) do
          ivar = "@#{setting}"
          next instance_variable_get(ivar) if instance_variable_defined?(ivar)
          superclass.respond_to?(setting) ? superclass.public_send(setting) : nil
        end
      end

      def authenticate_with(model:, session_key: :user_id, unauthenticated_redirect_path: nil,
                             remember_cookie: nil, remember_sessions: nil, remember_sessions_foreign_key: :user_id,
                             max_remember_sessions: nil)
        if remember_cookie && remember_sessions
          raise ArgumentError, 'authenticate_with accepts either remember_cookie: or remember_sessions:, not both'
        end
        if max_remember_sessions && !remember_sessions
          raise ArgumentError, 'max_remember_sessions: requires remember_sessions: to also be given'
        end
        self.authenticatable_model = model
        self.authenticatable_session_key = session_key
        self.unauthenticated_redirect_path = unauthenticated_redirect_path
        self.authenticatable_remember_cookie = remember_cookie
        self.authenticatable_remember_sessions_model = remember_sessions
        self.authenticatable_remember_sessions_foreign_key = remember_sessions_foreign_key
        self.authenticatable_max_remember_sessions = max_remember_sessions
      end
    end

    def current_user
      return @current_user if defined?(@current_user)
      id = session[authenticatable_session_key]
      @current_user = id ? authenticatable_model.find_by(id: id) : user_from_remember_cookie
    end

    def user_signed_in?
      !current_user.nil?
    end

    def current_login_session
      return @current_login_session if defined?(@current_login_session)
      @current_login_session = nil
      return @current_login_session unless authenticatable_remember_sessions_model
      current_user
      id = session[:login_session_id]
      @current_login_session = id ? authenticatable_remember_sessions_model.find_by(id: id) : nil
    end

    def other_login_sessions
      return authenticatable_remember_sessions_model.none unless authenticatable_remember_sessions_model
      return authenticatable_remember_sessions_model.none unless current_user
      scope = authenticatable_remember_sessions_model.where(authenticatable_remember_sessions_foreign_key => current_user.id)
      here = current_login_session
      here ? scope.not(id: here.id) : scope
    end

    def sign_out_all_other_sessions
      other_login_sessions.each(&:destroy)
    end

    def revoke_login_session!(id)
      return false unless authenticatable_remember_sessions_model && current_user
      target = authenticatable_remember_sessions_model.find_by(
        id: id.to_i, authenticatable_remember_sessions_foreign_key => current_user.id
      )
      return false unless target
      target.destroy
      forget_current_login_session_cookie if current_login_session && current_login_session.id == target.id
      true
    end

    def sign_in(user, remember: false)
      session[authenticatable_session_key] = user.id
      @current_user = user
      if remember
        remember_user(user)
      elsif authenticatable_remember_sessions_model
        session.delete(:login_session_id)
        @current_login_session = nil
      end
    end

    def sign_out
      if authenticatable_remember_sessions_model
        current_login_session&.destroy
        forget_current_login_session_cookie
      elsif authenticatable_remember_cookie
        forget_user(current_user)
      end
      session.delete(authenticatable_session_key)
      @current_user = nil
      @current_login_session = nil
    end

    def require_authentication
      return if user_signed_in?
      session[:return_to_after_authenticating] = request.path
      respond_to_unauthenticated
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || '/'
    end

    private

    def authenticatable_model
      configured = self.class.authenticatable_model
      raise "#{self.class} must call authenticate_with model: SomeModel" unless configured
      configured.is_a?(Module) ? configured : Object.const_get(configured.to_s)
    end

    def authenticatable_session_key
      self.class.authenticatable_session_key || :user_id
    end

    def authenticatable_remember_cookie
      self.class.authenticatable_remember_cookie
    end

    def authenticatable_remember_sessions_model
      configured = self.class.authenticatable_remember_sessions_model
      return nil unless configured
      configured.is_a?(Module) ? configured : Object.const_get(configured.to_s)
    end

    def authenticatable_remember_sessions_foreign_key
      (self.class.authenticatable_remember_sessions_foreign_key || :user_id).to_s
    end

    def authenticatable_max_remember_sessions
      self.class.authenticatable_max_remember_sessions
    end

    def user_from_remember_cookie
      if authenticatable_remember_sessions_model
        user_from_remember_session_cookie
      elsif authenticatable_remember_cookie
        user_from_remember_column_cookie
      end
    end

    def user_from_remember_session_cookie
      token = cookies.signed[REMEMBER_SESSION_COOKIE]
      return nil unless token
      login_session = authenticatable_remember_sessions_model.find_by(token: token)
      return nil unless login_session
      user = authenticatable_model.find_by(id: login_session[authenticatable_remember_sessions_foreign_key])
      return nil unless user
      session[authenticatable_session_key] = user.id
      session[:login_session_id] = login_session.id
      user
    end

    def user_from_remember_column_cookie
      token = cookies.signed[authenticatable_remember_cookie]
      return nil unless token
      user = authenticatable_model.find_by(authenticatable_remember_cookie => token)
      session[authenticatable_session_key] = user.id if user
      user
    end

    def remember_user(user)
      if authenticatable_remember_sessions_model
        remember_user_with_session(user)
      elsif authenticatable_remember_cookie
        remember_user_with_column(user)
      else
        raise "#{self.class} must pass remember_cookie: or remember_sessions: to authenticate_with " \
              'to use sign_in(remember: true)'
      end
    end

    def remember_user_with_session(user)
      model = authenticatable_remember_sessions_model
      attributes = { authenticatable_remember_sessions_foreign_key => user.id }
      attributes['user_agent'] = request.user_agent if model.columns.include?('user_agent')
      attributes['ip_address'] = request.remote_addr if model.columns.include?('ip_address')
      login_session = model.create!(attributes)
      session[:login_session_id] = login_session.id
      @current_login_session = login_session
      cookies.signed[REMEMBER_SESSION_COOKIE] = { value: login_session.token, max_age: REMEMBER_COOKIE_MAX_AGE }
      prune_oldest_login_sessions(user)
    end

    def prune_oldest_login_sessions(user)
      limit = authenticatable_max_remember_sessions
      return unless limit
      model = authenticatable_remember_sessions_model
      sessions = model.where(authenticatable_remember_sessions_foreign_key => user.id).order(:id, :asc).to_a
      overflow = sessions.size - limit
      return if overflow <= 0
      sessions.first(overflow).each(&:destroy)
    end

    def remember_user_with_column(user)
      column = authenticatable_remember_cookie
      user.send("regenerate_#{column}!") if user.send(column).to_s.empty?
      cookies.signed[column] = { value: user.send(column), max_age: REMEMBER_COOKIE_MAX_AGE }
    end

    def forget_user(user)
      column = authenticatable_remember_cookie
      user.send("regenerate_#{column}!") if user && user.persisted?
      cookies.set(column, '', max_age: 0)
    end

    def forget_current_login_session_cookie
      cookies.set(REMEMBER_SESSION_COOKIE, '', max_age: 0)
      session.delete(:login_session_id)
    end

    def respond_to_unauthenticated
      path = self.class.unauthenticated_redirect_path
      path ? redirect(path) : halt(401, 'authentication required')
    end
  end
end
