module Prism
  # Session-based authentication for a Controller, the request-cycle
  # counterpart to Orm::SecurePassword: `authenticate_with model: User` wires
  # up `current_user`/`user_signed_in?`/`sign_in`/`sign_out`, and
  # `require_authentication` (attach it with `before_action`) redirects
  # anonymous requests while remembering where they were headed, like
  # Rails 8's generated authentication.
  module Authenticatable
    # ~20 years, the same "forever" horizon Rails' cookies.permanent uses -
    # long enough that in practice a remember-me cookie only ever ends
    # because of an explicit sign_out (which rotates/destroys the token) or
    # the user clearing cookies, not calendar expiry.
    REMEMBER_COOKIE_MAX_AGE = 20 * 365 * 24 * 60 * 60

    # Fixed cookie name for the `remember_sessions:` mechanism - unlike
    # `remember_cookie:` (whose cookie is named after the column it lives
    # in on the user itself), a login-session token does not live on the
    # user at all, so there is no column name to borrow.
    REMEMBER_SESSION_COOKIE = :remember_session_token

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      attr_writer :authenticatable_model, :authenticatable_session_key, :unauthenticated_redirect_path,
                  :authenticatable_remember_cookie, :authenticatable_remember_sessions_model,
                  :authenticatable_remember_sessions_foreign_key, :authenticatable_max_remember_sessions

      # Falls back to the superclass's configuration, the same way
      # Controller#layout/#views_root do, so an ApplicationController can
      # call `authenticate_with` once and have every subclass see it -
      # otherwise a plain `PostsController < ApplicationController` would
      # silently see unconfigured (nil) settings and fall through to a bare
      # 401 instead of the configured redirect.
      %i[authenticatable_model authenticatable_session_key unauthenticated_redirect_path
         authenticatable_remember_cookie authenticatable_remember_sessions_model
         authenticatable_remember_sessions_foreign_key authenticatable_max_remember_sessions].each do |setting|
        define_method(setting) do
          ivar = "@#{setting}"
          next instance_variable_get(ivar) if instance_variable_defined?(ivar)
          superclass.respond_to?(setting) ? superclass.public_send(setting) : nil
        end
      end

      # `remember_cookie:` names the has_secure_token column (see
      # Orm::SecureToken) that backs "remember me" - nil (the default)
      # keeps sign_in/sign_out session-only, matching every controller
      # written before this option existed. It is a SINGLE token per user:
      # every browser that ever checked "remember me" shares the same
      # column, so `sign_out` from any one of them rotates the token and
      # silently signs the user out everywhere else too.
      #
      # `remember_sessions:` is the multi-device alternative - a model
      # (e.g. `LoginSession`) with its own `has_secure_token :token` column
      # and a foreign key back to the user (`remember_sessions_foreign_key:`,
      # default `:user_id`). Each `sign_in(remember: true)` creates its own
      # row instead of overwriting a shared column, so signing out of one
      # browser leaves every other remembered browser's session intact -
      # see `other_login_sessions`/`sign_out_all_other_sessions`/
      # `revoke_login_session!` below for managing them. Mutually exclusive
      # with `remember_cookie:`.
      #
      # `max_remember_sessions:` (only meaningful with `remember_sessions:`)
      # caps how many rows a single user may accumulate - without it,
      # `remember_sessions:` grows without bound: every "remember me" sign-in
      # on every browser/device ever used adds a row that nothing ever prunes,
      # forever, even for a browser the user will never open again. When set,
      # each successful `remember` sign-in destroys the OLDEST sessions for
      # that user (by id, i.e. creation order) beyond the limit, so the newly
      # created one and the `limit - 1` most recent others survive - a device
      # pruned this way finds out the same way a `revoke_login_session!`'d one
      # does: its remember-cookie token no longer matches any row.
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

    # Session first (cheap, no cookie-signature verification), then the
    # persistent remember-me cookie - and if the cookie is what answered,
    # the session is repopulated so the *next* request on this same
    # browser is back to the fast path instead of re-checking the cookie
    # every time.
    def current_user
      return @current_user if defined?(@current_user)
      id = session[authenticatable_session_key]
      @current_user = id ? authenticatable_model.find_by(id: id) : user_from_remember_cookie
    end

    def user_signed_in?
      !current_user.nil?
    end

    # The `remember_sessions:` row this request is authenticated through -
    # nil if that mechanism is not configured, or if this request is not
    # (and never has been, on this browser) remembered at all. Resolves via
    # `session[:login_session_id]`, which is set both by a fresh
    # `sign_in(remember: true)` and by the remember-cookie fallback in
    # `current_user`, so it stays correct across requests on the fast path
    # (plain session cookie) as well as the cold-start one (only the
    # persistent cookie survived).
    def current_login_session
      return @current_login_session if defined?(@current_login_session)
      @current_login_session = nil
      return @current_login_session unless authenticatable_remember_sessions_model
      current_user
      id = session[:login_session_id]
      @current_login_session = id ? authenticatable_remember_sessions_model.find_by(id: id) : nil
    end

    # Every OTHER remembered login for the current user - the list a
    # "manage your devices" screen shows, deliberately excluding whichever
    # one answered for the current request.
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

    # Destroys one login session by id, but only if it belongs to the
    # current user - a device-management screen calls this from a button
    # per row, and this is the one place that has to check ownership
    # itself (there is no controller-level `authorize` call for a plain
    # id posted from a form). Returns false (no-op) for a foreign or
    # already-gone id instead of raising, since "revoke" on something
    # that is not there anymore is not an error from the caller's view.
    #
    # `id` is coerced with #to_i: unlike Model.find (which goes through
    # Store#find and coerces internally), find_by compares with == and
    # does not, so the raw String a controller reads straight out of
    # params['id'] would otherwise never match the Integer id on the row
    # and this would silently no-op on every real HTTP request - the same
    # gotcha NestedAttributes#find_existing_nested_record and
    # PostsController#restore already work around the same way.
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

    # Ends the current login: for `remember_cookie:`, rotates the shared
    # token (not just deletes the cookie) so a copy of the old cookie
    # value - already sitting in a proxy log, another browser tab,
    # wherever - stops working immediately, everywhere, instead of
    # remaining valid until it naturally expires. For `remember_sessions:`,
    # destroys only THIS ONE login-session row, leaving every other
    # remembered browser signed in exactly as before.
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

    # Where to send the user once they do sign in: the page they were
    # trying to reach before `require_authentication` intercepted them, or
    # '/' if they arrived at the sign-in page directly.
    def after_authentication_url
      session.delete(:return_to_after_authenticating) || '/'
    end

    private

    # Accepts either the model class itself or its name as a String/Symbol
    # (resolved lazily, the same way Associable resolves `class_name:`), so
    # `authenticate_with` can be declared before the model class exists yet
    # (e.g. load order, or a model built dynamically in a test).
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

    # Destroys the oldest rows for `user` beyond `max_remember_sessions:`, if
    # configured. The row just created above is always the newest by id, so
    # it is never among the ones pruned here (unless the limit is 0, which
    # would prune it too - authenticate_with does not special-case that,
    # matching Devise's own `0 means never remembered` behavior for a
    # deliberately-set zero).
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
