require 'facet'
require 'fileutils'

APP_ROOT = __dir__

DB_DIR = ENV.fetch('FACET_BLOG_DB_DIR', File.join(APP_ROOT, 'db'))
FileUtils.mkdir_p(DB_DIR)

Facet::Orm.connect(File.join(DB_DIR, 'development.pstore'))
Facet::Orm.migrator(File.join(APP_ROOT, 'db', 'migrate')).migrate!

Facet::Jobs.default_queue = Facet::Jobs::Queue.new(File.join(DB_DIR, 'jobs.pstore'))
Facet::Mailer.delivery_method = :test

Facet::RateLimiter.store = Facet::RateLimiter::PStoreStore.new(File.join(DB_DIR, 'rate_limits.pstore'))

Facet::I18n.default_locale = :en
Facet::I18n.load_path << File.join(APP_ROOT, 'config', 'locales')
Facet::I18n.load_translations!

LOG_DIR = File.join(APP_ROOT, 'log')
Dir.mkdir(LOG_DIR) unless Dir.exist?(LOG_DIR)
DEVELOPMENT_LOG = File.open(File.join(LOG_DIR, 'development.log'), 'a')
DEVELOPMENT_LOG.sync = true
Facet::Instrumentation::LogSubscriber.attach(
  DEVELOPMENT_LOG,
  patterns: %w[sql.facet render_template.facet process_action.facet perform_job.facet deliver_mail.facet]
)

Facet::Controller.views_root(File.join(APP_ROOT, 'app', 'views'))
Facet::Controller.layout(:application)

Dir[File.join(APP_ROOT, 'app', 'models', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'mailers', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'policies', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'channels', '*.rb')].sort.each { |file| require file }
require File.join(APP_ROOT, 'app', 'controllers', 'application_controller.rb')
Dir[File.join(APP_ROOT, 'app', 'controllers', '*.rb')].sort.each { |file| require file }

def throttled_path(req, base)
  req.path.sub(%r{\.[^./]+\z}, '') == base
end

Facet::RateLimiter.throttle('logins/ip', limit: 5, period: 60) do |req|
  throttled_path(req, '/session') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

Facet::RateLimiter.throttle('signups/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/users') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

Facet::RateLimiter.throttle('password_resets/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/password_resets') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

Facet::RateLimiter.throttle('email_confirmations/ip', limit: 3, period: 60) do |req|
  throttled_path(req, '/email_confirmations') && req.request_method == 'POST' ? req.env['REMOTE_ADDR'] : nil
end

Facet::Cors.configure do |config|
  config.allow do
    origins 'https://admin.blog.example.com'
    resource '/posts', methods: %w[GET POST], headers: %w[Content-Type X-CSRF-Token], credentials: true
    resource '/posts/*', methods: %w[GET PATCH DELETE], headers: %w[Content-Type X-CSRF-Token], credentials: true
  end

  config.allow do
    origins '*'
    resource '/posts', methods: %w[GET]
    resource '/posts/*', methods: %w[GET]
  end
end

class Blog < Facet::Application
  set :views, File.join(APP_ROOT, 'app', 'views')
  enable_sessions(
    secret: ENV.fetch('FACET_BLOG_SESSION_SECRET', 'blog-demo-secret'),
    previous_secrets: ENV['FACET_BLOG_SESSION_PREVIOUS_SECRETS'].to_s.split(',')
  )
  enable_attribute_encryption(
    secret: ENV.fetch('FACET_BLOG_ENCRYPTION_SECRET', 'blog-demo-encryption-secret'),
    previous_secrets: ENV['FACET_BLOG_ENCRYPTION_PREVIOUS_SECRETS'].to_s.split(',')
  )
  enable_token_signing(
    secret: ENV.fetch('FACET_BLOG_TOKEN_SECRET', 'blog-demo-token-secret'),
    previous_secrets: ENV['FACET_BLOG_TOKEN_PREVIOUS_SECRETS'].to_s.split(',')
  )
  enable_assets(source: File.join(APP_ROOT, 'app', 'assets'), output: File.join(APP_ROOT, 'public', 'assets'))
  use Facet::Middleware::Logger
  use Facet::Middleware::Compression
  use Facet::Middleware::Cors
  use Facet::Middleware::ParamsParser
  use Facet::Middleware::RateLimiting
  use Facet::Middleware::Static, root: File.join(APP_ROOT, 'public')

  enable_n_plus_one_detection(threshold: 2, raise_on_violation: ENV['FACET_BLOG_STRICT_N_PLUS_ONE'] == '1')
  enable_mailer(host: 'localhost', port: 4567)
  mount '/rails/mailers', Facet::Mailer::PreviewApp.new
  websocket '/cable', PostActivityChannel, max_message_size: 2048

  root(to: 'posts#index')
  resource :session, only: %i[new create destroy]
  get('/password_resets/new', to: 'password_resets#new', as: :new_password_reset)
  post('/password_resets', to: 'password_resets#create', as: :password_resets)
  get('/password_resets/:token/edit', to: 'password_resets#edit', as: :edit_password_reset)
  patch('/password_resets/:token', to: 'password_resets#update', as: :password_reset)
  get('/email_confirmations/new', to: 'email_confirmations#new', as: :new_email_confirmation)
  post('/email_confirmations', to: 'email_confirmations#create', as: :email_confirmations)
  get('/email_confirmations/:token', to: 'email_confirmations#show', as: :email_confirmation)
  resource :account, only: %i[edit update]
  get('/account/comments', to: 'account#comments', as: :account_comments)
  get('/account/moderation', to: 'account#moderation', as: :account_moderation)
  resources :users, only: %i[new create]
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
    resources :claims, only: %i[create]
  end
  get('/comments/trash', to: 'comments#trash', as: :trash_comments)
  patch('/comments/:id/restore', to: 'comments#restore', as: :restore_comment)
  resources :likes, only: %i[create destroy]
  resources :login_sessions, only: %i[index destroy] do
    collection do
      post(:sign_out_others)
    end
  end
end
