require 'prism'

APP_ROOT = __dir__

Prism::Orm.connect(File.join(APP_ROOT, 'db', 'development.pstore'))
Prism::Orm.migrator(File.join(APP_ROOT, 'db', 'migrate')).migrate!

Prism::Controller.views_root(File.join(APP_ROOT, 'app', 'views'))
Prism::Controller.layout(:application)

Dir[File.join(APP_ROOT, 'app', 'models', '*.rb')].sort.each { |file| require file }
Dir[File.join(APP_ROOT, 'app', 'controllers', '*.rb')].sort.each { |file| require file }

class Blog < Prism::Application
  set :views, File.join(APP_ROOT, 'app', 'views')
  enable_sessions(secret: 'blog-demo-secret')
  use Prism::Middleware::Logger
  use Prism::Middleware::ParamsParser
  use Prism::Middleware::Static, root: File.join(APP_ROOT, 'public')

  root(to: 'posts#index')
  resources :posts, only: %i[index show create]
end
