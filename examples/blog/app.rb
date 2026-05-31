require 'prism'
require 'fileutils'

APP_ROOT = __dir__

# Both overridable by ENV so a second, independent OS process (see
# rotation_worker.rb) can boot this exact app against its own scratch
# database and its own encryption secret without touching development.pstore
# - key rotation genuinely retires the OLD secret from the running process'
# memoized, per-model derived keys, so exercising it for real needs a fresh
# `ruby` invocation, not just a different in-process config call.
DB_DIR = ENV.fetch('PRISM_BLOG_DB_DIR', File.join(APP_ROOT, 'db'))
FileUtils.mkdir_p(DB_DIR)

Prism::Orm.connect(File.join(DB_DIR, 'development.pstore'))
Prism::Orm.migrator(File.join(APP_ROOT, 'db', 'migrate')).migrate!

Prism::Jobs.default_queue = Prism::Jobs::Queue.new(File.join(DB_DIR, 'jobs.pstore'))
Prism::Mailer.delivery_method = :test

# PStoreStore instead of the default in-memory RateLimiter::MemoryStore -
# throttle windows and fail2ban-style bans survive a process restart the
# same way development.pstore/jobs.pstore already do. Without this, an
# attacker who gets banned right before a deploy (a plain process restart)
# would find the ban silently gone the moment the new process comes up,
# since MemoryStore keeps every window and ban only in that one process'
# RAM. See blog_rate_limit_worker.rb for the two-process proof.
Prism::RateLimiter.store = Prism::RateLimiter::PStoreStore.new(File.join(DB_DIR, 'rate_limits.pstore'))

Prism::I18n.default_locale = :en
Prism::I18n.load_path << File.join(APP_ROOT, 'config', 'locales')
Prism::I18n.load_translations!

LOG_DIR = File.join(APP_ROOT, 'log')
Dir.mkdir(LOG_DIR) unless Dir.exist?(LOG_DIR)
DEVELOPMENT_LOG = File.open(File.join(LOG_DIR, 'development.log'), 'a')
DEVELOPMENT_LOG.sync = true
Prism::Instrumentation::LogSubscriber.attach(
  DEVELOPMENT_LOG,
  patterns: %w[sql.prism render_template.prism process_action.prism perform_job.prism deliver_mail.prism]
)

Prism::Controller.views_root(File.join(APP_ROOT, 'app', 'views'))
Prism::Controller.layout(:application)

Dir[File.join(APP_ROOT, 'app', 'models', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'mailers', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'policies', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'channels', '*.rb')].sort.each { |file| require file }
# application_controller.rb has to load before every other controller
# (they all subclass it) - a plain alphabetical sort no longer guarantees
# that on its own now that account_controller.rb sorts ahead of it.
require File.join(APP_ROOT, 'app', 'controllers', 'application_controller.rb')
Dir[File.join(APP_ROOT, 'app', 'controllers', '*.rb')].sort.each { |file| require file }

# req.path is the raw PATH_INFO - the router only strips a trailing
# ".json" (etc) internally while matching, so without stripping it here
# too a POST to /session.json would silently dodge this throttle
# entirely (same account, same IP, just a different extension).
def throttled_path(req, base)
  req.path.sub(%r{\.[^./]+\z}, '') == base
end

Prism::RateLimiter.throttle('logins/ip', limit: 5, period: 60) do |req|
  throttled_path(req, '/session') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

Prism::RateLimiter.throttle('signups/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/users') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

# Same shape as signups/ip above, same reason: #create's response is
# identical whether or not the email exists (see the comment on
# PasswordResetsController#create), but without a limit here that endpoint
# would still let an attacker hammer arbitrary addresses with reset emails
# for free.
Prism::RateLimiter.throttle('password_resets/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/password_resets') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

# Same shape and reason as password_resets/ip above: #create's response is
# identical whether or not the address exists or is already confirmed, but
# without a limit here that endpoint would let an attacker hammer arbitrary
# addresses with confirmation emails for free.
Prism::RateLimiter.throttle('email_confirmations/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/email_confirmations') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

# Two separate rules on purpose: the .json API is meant to be embeddable
# by anyone (a "latest posts" widget on a third-party site), but only the
# trusted admin dashboard origin gets to write through it, and only that
# origin is allowed to send the session cookie cross-origin at all. The
# specific origin is registered FIRST - Prism::Cors.resource_for returns
# the first rule whose origin matches, and '*' matches every origin, so a
# wildcard rule ahead of this one would shadow it for every request.
Prism::Cors.configure do |config|
  config.allow do
    origins 'https://admin.blog-demo.internal'
    resource '/posts', methods: %w[GET POST], headers: %w[Content-Type X-CSRF-Token], credentials: true
    resource '/posts/*', methods: %w[GET PATCH DELETE], headers: %w[Content-Type X-CSRF-Token], credentials: true
  end

  config.allow do
    origins '*'
    resource '/posts', methods: %w[GET]
    resource '/posts/*', methods: %w[GET]
  end
end

class Blog < Prism::Application
  set :views, File.join(APP_ROOT, 'app', 'views')
  enable_sessions(
    secret: ENV.fetch('PRISM_BLOG_SESSION_SECRET', 'blog-demo-secret'),
    previous_secrets: ENV['PRISM_BLOG_SESSION_PREVIOUS_SECRETS'].to_s.split(',')
  )
  enable_attribute_encryption(
    secret: ENV.fetch('PRISM_BLOG_ENCRYPTION_SECRET', 'blog-demo-encryption-secret'),
    previous_secrets: ENV['PRISM_BLOG_ENCRYPTION_PREVIOUS_SECRETS'].to_s.split(',')
  )
  # Backs User.generates_token_for(:password_reset) - a separate secret
  # (own ENV var, own rotation list) from both session and encryption above
  # on purpose: retiring this one to kill every outstanding reset link
  # (say, right after the leak a rotation is usually responding to) should
  # never force-log-out every signed-in visitor or break decryption of
  # already-encrypted columns as a side effect.
  enable_token_signing(
    secret: ENV.fetch('PRISM_BLOG_TOKEN_SECRET', 'blog-demo-token-secret'),
    previous_secrets: ENV['PRISM_BLOG_TOKEN_PREVIOUS_SECRETS'].to_s.split(',')
  )
  enable_assets(source: File.join(APP_ROOT, 'app', 'assets'), output: File.join(APP_ROOT, 'public', 'assets'))
  use Prism::Middleware::Logger
  use Prism::Middleware::Compression
  use Prism::Middleware::Cors
  use Prism::Middleware::ParamsParser
  use Prism::Middleware::RateLimiting
  use Prism::Middleware::Static, root: File.join(APP_ROOT, 'public')

  # Log-only by default so a detected N+1 shows up in the dev log the same
  # way Bullet would, without ever turning an otherwise fine response into a
  # 500 - this app's controllers already lean hard on .includes (see
  # PostsController#index/#show) specifically to avoid the pattern this
  # exists to catch, so in steady state this should stay silent; a warning
  # here is a real regression, not a false positive.
  #
  # PRISM_BLOG_STRICT_N_PLUS_ONE=1 flips raise_on_violation on - meant for
  # CI/test runs of this demo, where a regression should fail the run
  # instead of scrolling past in a log nobody re-reads. Application#dispatch
  # routes a violation through the same handle_uncaught_exception path as
  # any other bug, so this always surfaces as a normal 500 over real HTTP
  # (see strict_n_plus_one_demo.rb, which proves that end-to-end against a
  # deliberately reintroduced N+1 through a real socket).
  enable_n_plus_one_detection(threshold: 2, raise_on_violation: ENV['PRISM_BLOG_STRICT_N_PLUS_ONE'] == '1')
  enable_mailer(host: 'localhost', port: 4567)
  mount '/rails/mailers', Prism::Mailer::PreviewApp.new
  # PostActivityChannel only ever pushes small JSON control/notification
  # frames (subscribe acks, comment-count updates) and never acts on
  # anything a client sends (see #on_message) - 2 KiB is generous headroom
  # over the largest real payload while still being a meaningfully tighter
  # cap than Connection::DEFAULT_MAX_MESSAGE_SIZE's 16 MiB, so a client
  # that tries to abuse this read-mostly stream gets cut off quickly
  # instead of being allowed to buffer up to the library-wide default.
  websocket '/cable', PostActivityChannel, max_message_size: 2048

  root(to: 'posts#index')
  resource :session, only: %i[new create destroy]
  # Not a `resource`/`resources` - the record this is "about" is only ever
  # addressed by a signed token in the URL, never by a User id (that would
  # let anyone reset any account by guessing/incrementing ids), so it has
  # no numeric-id member routes to fall out of that DSL.
  get('/password_resets/new', to: 'password_resets#new', as: :new_password_reset)
  post('/password_resets', to: 'password_resets#create', as: :password_resets)
  get('/password_resets/:token/edit', to: 'password_resets#edit', as: :edit_password_reset)
  patch('/password_resets/:token', to: 'password_resets#update', as: :password_reset)
  # Same reasoning as password_resets above - addressed only by a signed
  # token, never by User id.
  get('/email_confirmations/new', to: 'email_confirmations#new', as: :new_email_confirmation)
  post('/email_confirmations', to: 'email_confirmations#create', as: :email_confirmations)
  get('/email_confirmations/:token', to: 'email_confirmations#show', as: :email_confirmation)
  resource :account, only: %i[edit update]
  # Flat, not nested under a post - a user's own comment history spans every
  # post they ever commented on, same shape as GET /comments/trash below but
  # for live (not soft-deleted) comments. See AccountController#comments.
  get('/account/comments', to: 'account#comments', as: :account_comments)
  # Flat, same reasoning as /account/comments above but filtered to
  # pending instead of to authorship - see AccountController#moderation.
  get('/account/moderation', to: 'account#moderation', as: :account_moderation)
  resources :users, only: %i[new create]
  # param: :slug - post URLs are /posts/some-title, not /posts/42 (see
  # Post#to_param and Post.create_with_unique_slug). Nested comment routes
  # stay /posts/:post_id/... (ResourceScope#nested_prefix hardcodes the
  # segment name to "#{singular}_id" regardless of the parent's own param -
  # only the VALUE passed for that segment becomes a slug string instead of
  # a numeric id, see CommentsController).
  resources :posts, only: %i[index show create edit update destroy], param: :slug do
    collection do
      get(:trash)
      get(:export)
      post(:import)
    end
    member do
      patch(:preview)
      patch(:publish)
      patch(:unpublish)
      patch(:restore)
      patch(:move_up)
      patch(:move_down)
    end
    resources :comments, only: %i[index create edit update destroy] do
      member do
        patch(:approve)
        patch(:reject)
      end
    end
    # create-only - see ClaimsController, a claim has no update/destroy
    # anywhere in this app.
    resources :claims, only: %i[create]
  end
  # Flat, not nested under a post - a commenter's own trashed comments span
  # every post they ever wrote on, and restoring one is independent of
  # whatever trash/restore state its post happens to be in (see
  # CommentsController#trash/#restore).
  get('/comments/trash', to: 'comments#trash', as: :trash_comments)
  patch('/comments/:id/restore', to: 'comments#restore', as: :restore_comment)
  resources :likes, only: %i[create destroy]
  resources :login_sessions, only: %i[index destroy] do
    collection do
      post(:sign_out_others)
    end
  end
end
