# Prism

A Ruby web framework, standard library only (socket, json, uri, cgi, digest,
openssl, pstore, minitest). No bundler, no external gems. Started as a small
Sinatra-style microframework and grew a controller layer, a file-backed ORM
with migrations and associations, layouts/partials, flash messages, a static
file server and a CLI generator on top of the original routing DSL, request/
response objects, middleware stack and its own HTTP/1.1 server.

## Requirements

Ruby 3.3.x. This project targets the user-space build at `~/.local/ruby`:

    export PATH="$HOME/.local/ruby/bin:$PATH"

`gem install sqlite3` does not work on every host (rubygems itself needs
`psych`, which needs libyaml headers that are not always installed). Prism
never depends on it: persistence is a real file-backed store built on the
standard library's `PStore`, described below.

## Layout

    lib/prism.rb                       top-level require aggregator
    lib/prism/support/inflector.rb     underscore/camelize/pluralize/tableize
    lib/prism/params.rb                indifferent-access params hash
    lib/prism/template.rb              ERB-like renderer with HTML escaping
    lib/prism/view.rb                  file-based templates, layouts, partials
    lib/prism/session.rb               HMAC-SHA256 signed cookie encode/decode
    lib/prism/flash.rb                 one-request-lifetime session flash
    lib/prism/request.rb               method, path, query, body, cookies, params
    lib/prism/response.rb              status, headers, body, cookies
    lib/prism/router.rb                PathMatcher, Route, Router, named routes
    lib/prism/renderable.rb            params/session/flash/render helpers shared
                                        by Application and Controller
    lib/prism/middleware.rb            Rack-style middleware stack builder
    lib/prism/middleware/logger.rb     request logger
    lib/prism/middleware/session.rb    load/save session as signed cookie
    lib/prism/middleware/static.rb     static file server (with index.html support)
    lib/prism/middleware/params.rb     rejects malformed JSON bodies with 400
    lib/prism/application.rb           DSL, dispatch, filters, resources, url_for
    lib/prism/controller.rb            Controller base: actions, before/after_action
    lib/prism/server.rb                HTTP/1.1 server on TCPServer
    lib/prism/orm.rb                   Prism::Orm.connect / .store / .transaction
    lib/prism/orm/store.rb             file-backed table store (PStore/Marshal)
    lib/prism/orm/model.rb             Model: CRUD, dynamic attributes, timestamps
    lib/prism/orm/relation.rb          where/order/limit/offset query builder
    lib/prism/orm/validatable.rb       presence/uniqueness/format/length validators
    lib/prism/orm/associable.rb        belongs_to / has_many
    lib/prism/orm/migration.rb         create_table/add_column DSL for migrations
    lib/prism/orm/migrator.rb          runs/rolls back migrations, tracks versions
    lib/prism/orm/errors.rb            per-attribute validation error collector
    lib/prism/cli.rb                   Prism::Cli: new app / generate migration|model
    bin/prism                          `prism new blog`, `prism generate model post ...`
    examples/app.rb                    original Sinatra-style sample application
    examples/blog/                     full mini-Rails app: model+migration+
                                        controller+views+sessions, scaffolded by
                                        `Prism::Cli` itself
    demo.rb                            boots examples/app.rb and hits it over HTTP
    blog_demo.rb                       boots examples/blog and does a POST+GET
                                        round trip through the ORM and the views
    test/                              minitest suite

## Defining a Sinatra-style app

    require 'prism'

    class Blog < Prism::Application
      enable_sessions(secret: 'change-me')
      use Prism::Middleware::Logger

      get '/' do
        html('<h1>Prism</h1>')
      end

      get '/users/:id' do
        json(id: params['id'])
      end

      get '/files/*' do
        json(path: params['splat'])
      end

      group '/api' do
        get '/status' do
          json(ok: true)
        end
      end

      post '/echo' do
        json(received: params.to_h)
      end
    end

Params merge path, query and body (path wins). Template output is HTML-escaped
with `<%= %>`; use `<%== %>` for raw output.

## Controllers, resources and views

    class PostsController < Prism::Controller
      layout :application
      before_action :require_login, except: %i[index show]

      def index
        render(:index, locals: { posts: Post.order(:created_at, :desc) })
      end

      def create
        post = Post.new(title: params['title'])
        if post.save
          flash[:notice] = 'Post created'
          redirect url_for(:posts)
        else
          status(422)
          render(:index, locals: { posts: Post.all, errors: post.errors.full_messages })
        end
      end
    end

    class Blog < Prism::Application
      root(to: 'posts#index')
      resources :posts, only: %i[index show create]
    end

`app/views/posts/index.erb` is wrapped in `app/views/layouts/application.erb`
(the layout reads the rendered page through a local called `content`, not
Ruby's `yield`, since ERB templates are `eval`'d in a fresh binding rather than
inside the layout's own block). Partials live alongside the view they belong
to, prefixed with an underscore, and are called from inside a template with
`partial('post', locals: { post: post })` or with a whole collection via
`render_collection`/`Controller#render_each`.

## ORM-lite over a file-backed store

There is no SQLite dependency. `Prism::Orm::Store` persists tables to a single
file with `PStore` (Marshal under the hood), including multi-statement atomic
transactions with rollback on exception, and the data is still there the next
time a process opens the same file - see `test/test_orm_store.rb`'s
`test_data_survives_reopening_the_store` and
`test/test_integration_orm.rb`'s full HTTP round trip across two independent
servers.

    Prism::Orm.connect('db/development.pstore')
    Prism::Orm.migrator('db/migrate').migrate!

    class Post < Prism::Orm::Model
      validates :title, presence: true, length: { minimum: 3 }
      belongs_to :author, class_name: 'User'
    end

    class User < Prism::Orm::Model
      has_many :posts, foreign_key: 'author_id'
    end

    Post.where(title: 'Hello').order(:created_at, :desc).limit(10).offset(20)
    Post.create(title: 'Hi').errors.full_messages

Migrations subclass `Prism::Orm::Migration` and implement `up`/`down` with a
`create_table`/`add_column`/`remove_column`/`drop_table` DSL; `Migrator` tracks
applied versions inside the store itself and supports `migrate!`/`rollback!`.

## CLI generator

    bin/prism new blog
    cd blog
    ruby -I../lib ../bin/prism generate model post title:string body:text
    ruby -I../lib ../bin/prism generate migration add_published_to_posts
    ruby bin/server 3000

`prism new` scaffolds `app/{controllers,models,views}`, `db/migrate`, a boot
file that connects the store and runs pending migrations, `config.ru` and a
`bin/server` script. `generate model NAME field:type ...` writes both the
model and a matching `create_<table>` migration; `generate migration NAME` on
its own writes an empty `up`/`down` skeleton (or a `create_table` skeleton if
the name starts with `create_`).

## Running a server

    server = Prism::Server.new(Blog, port: 0).start
    puts server.url          # http://127.0.0.1:<ephemeral-port>
    # ...
    server.stop

Port 0 asks the OS for a free ephemeral port, read back via `server.port`.

## Tests

    ruby -Itest -Ilib test/run_all.rb

or, with rake:

    rake test

The suite covers routing (including named routes and `resources`), request
parsing, response building, the template and view engine, signed sessions and
flash, controllers and filters, the full ORM-lite stack (store, migrations,
models, validations, associations, the query builder, transactions), the
static file and JSON-body-guard middleware, the CLI generator (both in-process
and by shelling out to `bin/prism`), and HTTP integration tests that start the
server on an ephemeral port and drive it with `Net::HTTP`.

## Demos

    ruby demo.rb
    ruby blog_demo.rb

`demo.rb` boots `examples/app.rb` (the original Sinatra-style sample) and
performs real HTTP requests. `blog_demo.rb` boots `examples/blog` (a real
generated app with a model, a migration, a controller and views), POSTs a new
post through the ORM and renders it back with the ERB view; the data stays on
disk in `examples/blog/db/development.pstore` after the process exits, so a
second run of the demo (or of any script that reconnects to that file) sees
the previously created posts.
