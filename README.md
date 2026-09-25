# Facet

Facet is a Ruby web framework written against the standard library only: no
Bundler, no runtime gems. It covers the stack of a small Rails-style
application end to end - a Sinatra-style routing DSL and Rails-style
controllers and resources, ERB-like views with layouts, partials and form
helpers, a file-backed ORM with migrations, associations, validations and
indexes, background jobs, mailers, WebSockets, i18n, caching, security
helpers, a test toolkit and a CLI generator - all served by its own HTTP/1.1
server.

## Features

**HTTP and routing**
- HTTP/1.1 server on `TCPServer`: keep-alive, chunked streaming responses,
  WebSocket upgrades on the same port, optional cap on open WebSocket
  connections, ephemeral port support.
- Rack-style `call(env)` interface and middleware stack (`use`).
- Routing DSL: `get`/`post`/`put`/`patch`/`delete`, named parameters, splats,
  constraints, optional `.format` suffix, `group`, `namespace`, `before` and
  `after` filters, `pass`, `halt`, named routes and `url_for`.
- `resources` and `resource` with `only`/`except`, custom `param:`, nested
  resources, `member` and `collection` routes; `mount` for other Rack apps.
- Request object (query, form, JSON and multipart bodies, nested params with
  indifferent access, cookies, `_method` override) and response object
  (cookies, streaming).
- Content negotiation with `respond_to` and MIME lookup from `Accept`.
- Conditional GET (`fresh_when`, `stale?`, ETag and Last-Modified, 304/412)
  and byte ranges (`Range`, `If-Range`, 206/416) for static files.

**Controllers and views**
- Controllers with `before_action`/`after_action` (`only`/`except`),
  `rescue_from`, layouts, `render`, `partial`, `render_each`, `redirect`,
  `json`, `html`, `stream`, `render_errors` (JSON:API style), `render_not_found`.
- ERB-like template engine with escaped `<%= %>` and raw `<%== %>` output,
  `SafeString` output safety, layouts, partials, collections, `content_for`.
- View helpers: `form_for` with a form builder (text, email, password,
  number, date, text area, check box, select, hidden fields, `fields_for`,
  inline errors), `link_to`, `button_to`, `tag`/`content_tag`, pagination
  links, asset tags, fragment `cache`.
- Flash messages (`now`, `keep`, `discard`) and HMAC-signed cookie sessions
  with secret rotation.

**Middleware**
- Logger, signed sessions, static files (weak ETags, ranges, `index.html`),
  fingerprinted assets (strong ETags, long-lived caching), JSON body guard
  (400 on malformed JSON), gzip compression (buffered and streaming), CORS
  with preflight handling, rate limiting.

**ORM over a file-backed store**
- `PStore`-backed table store with atomic multi-statement transactions,
  savepoints (`requires_new`), unique and composite indexes, equality, range
  and `IN` lookups through indexes.
- Migrations (`create_table`, `add_column`, `remove_column`, `add_index`,
  `drop_table`, `timestamps`) with a migrator that tracks applied versions
  and supports rollback.
- Models: CRUD, typed attributes with defaults and casting, timestamps,
  callbacks including `after_commit`/`after_rollback`, dirty tracking,
  validations (presence, uniqueness with scope, format, length, numericality,
  inclusion, exclusion, custom), enums, JSON serialization with hidden
  attributes and included associations.
- Query interface: `where` with operators (`gt`, `lt`, `in`, `like`, ...),
  `not`, `or`, `order`, `limit`, `offset`, `distinct`, scopes and default
  scopes, `pluck`, `pick`, aggregates, `group`, `find_each`, pagination.
- Associations: `belongs_to` (polymorphic, `counter_cache`, `touch`),
  `has_one`, `has_many` (`through`, `as`, `dependent`),
  `has_and_belongs_to_many`, eager loading with `includes`, nested attributes.
- Optimistic locking (`lock_version`), pessimistic locking (`lock!`,
  `with_lock`), soft delete (`acts_as_paranoid`), ordered lists
  (`acts_as_list`), `has_secure_password` (PBKDF2), `has_secure_token`,
  `generates_token_for`, attribute encryption (AES-256-GCM, deterministic
  mode for lookups, key rotation), N+1 query detection.

**Background work and mail**
- Jobs with a persistent `PStore` queue: `perform_later` with `run_at`, named
  queues, retries with linear or exponential backoff, a dead-letter list,
  safe claiming across processes, and a `facet jobs work` daemon.
- Mailers with HTML and text templates, multipart messages and attachments,
  `deliver_now`/`deliver_later`, URL helpers, test and SMTP delivery, and a
  browser preview app.

**Real time, i18n, caching, instrumentation**
- WebSockets: handshake, framing, fragmentation, ping/pong, close codes,
  message size limits, and a pub/sub hub with per-stream subscriber limits.
- I18n: JSON locale files, interpolation, pluralization, fallbacks, date and
  time localization, locale from params, session or `Accept-Language`.
- In-memory cache store with expiry and size limit, used by fragment caching.
- Instrumentation bus with events for SQL, rendering, controller actions,
  jobs and mail, plus a log subscriber.

**Security**
- CSRF protection with masked tokens, strong parameters (`require`/`permit`),
  signed and encrypted cookies, `MessageVerifier` (expiry and purpose) and
  `MessageEncryptor`, secret rotation for sessions, cookies and tokens.
- Authentication module (`authenticate_with`): sign in and out, remember-me
  cookies backed by one row per device, device limit, revoking other sessions.
- Authorization with policy classes and policy scopes.
- Rate limiting: throttles, blocklists, safelists, tracks and a fail2ban
  filter, with in-memory or `PStore` storage shared across processes.

**Tooling**
- CLI: `new`, `generate model|migration`, `db:migrate`, `db:rollback`,
  `db:status`, `db:seed`, `routes`, `console`, `assets:precompile`,
  `jobs work`.
- Asset pipeline that fingerprints files and writes a manifest.
- Integration test helpers for Minitest: a cookie-keeping session, request
  helpers, `follow_redirect!`, response assertions and transactional tests.

## Requirements

Ruby 3.3 or newer. Nothing else: every library Facet uses ships with Ruby.

## Getting started

Use it straight from a checkout:

    git clone https://github.com/dualfroz/facet.git
    ruby -Ifacet/lib your_app.rb

or build and install the gem:

    gem build facet.gemspec
    gem install facet-0.1.0.gem

A minimal application:

    require 'facet'

    class Blog < Facet::Application
      enable_sessions(secret: 'change-me')
      use Facet::Middleware::Logger

      get '/' do
        html('<h1>Facet</h1>')
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

    server = Facet::Server.new(Blog, port: 3000).start
    puts server.url
    sleep

Params merge path, query and body values; path parameters win. Port 0 asks
the OS for a free port, read back with `server.port`.

## Controllers, resources and views

    class PostsController < Facet::Controller
      layout :application
      before_action :require_login, except: %i[index show]

      def index
        render(:index, locals: { posts: Post.order(:created_at, :desc) })
      end

      def create
        post = Post.new(params.require('post').permit(:title).to_h)
        if post.save
          flash[:notice] = 'Post created'
          redirect url_for(:posts)
        else
          status(422)
          render(:index, locals: { posts: Post.all, errors: post.errors.full_messages })
        end
      end
    end

    class Blog < Facet::Application
      root(to: 'posts#index')
      resources :posts, only: %i[index show create]
    end

`app/views/posts/index.erb` is wrapped in `app/views/layouts/application.erb`.
The layout reads the page through a local called `content`. Partials live
next to their view with a leading underscore and are rendered with
`partial('post', locals: { post: post })` or, for a collection,
`render_collection` / `render_each`.

## ORM

    Facet::Orm.connect('db/development.pstore')
    Facet::Orm.migrator('db/migrate').migrate!

    class Post < Facet::Orm::Model
      validates :title, presence: true, length: { minimum: 3 }
      belongs_to :author, class_name: 'User'
    end

    class User < Facet::Orm::Model
      has_many :posts, foreign_key: 'author_id'
    end

    Post.where(title: 'Hello').order(:created_at, :desc).limit(10).offset(20)
    Post.create(title: 'Hi').errors.full_messages

Migrations subclass `Facet::Orm::Migration` and implement `up` and `down`.
Data is written to a single file and survives process restarts.

## CLI

    bin/facet new blog
    cd blog
    ruby -I../lib ../bin/facet generate model post title:string body:text
    ruby -I../lib ../bin/facet generate migration add_published_to_posts
    ruby -I../lib bin/server 3000

`facet new` creates `app/{controllers,models,views}`, `db/migrate`, a boot file
that connects the store and runs pending migrations, `config.ru` and
`bin/server`. `generate model NAME field:type ...` writes the model and a
matching `create_<table>` migration. With the gem installed, `facet` is on
the `PATH` and the `-I` flags are not needed.

## Tests

    ruby -Itest -Ilib test/run_all.rb

or `rake test`. The Minitest suite (about 1500 tests) covers every module,
including HTTP integration tests that start the server on an ephemeral port,
WebSocket clients over real sockets, and multi-process tests for the job
queue, locking and the CLI. A few tests start `bin/facet` as a subprocess, so
the `ruby` on your `PATH` must be the one you run the suite with.

## Examples

`examples/` holds a small Sinatra-style app, a full blog application and
scripts that drive them over HTTP. See [examples/README.md](examples/README.md).

    ruby examples/demo.rb
    ruby examples/blog_demo.rb

## Layout

    bin/facet                 command line entry point
    facet.gemspec             gem specification
    lib/facet.rb              requires the whole framework
    lib/facet/
      application.rb          routing DSL, dispatch, filters, resources, mounts
      controller.rb           controller base: actions, filters, rescue_from
      router.rb               path matcher, routes, named routes, mounts
      resource_scope.rb       member/collection/nested resource routes
      request.rb              request parsing: params, body, cookies, format
      response.rb             status, headers, cookies, streaming
      streaming_body.rb       chunked response bodies
      renderable.rb           helpers shared by apps and controllers
      responder.rb            respond_to format blocks
      conditional_get.rb      fresh_when / stale?
      static_cache.rb         ETag and Last-Modified validators for files
      http_range.rb           Range header parsing and slicing
      mime.rb                 MIME types and Accept negotiation
      multipart.rb            multipart/form-data parsing, uploaded files
      params.rb               nested params with indifferent access
      session.rb              signed cookie encoding
      flash.rb                flash messages
      template.rb             template compiler and rendering context
      view.rb                 template lookup, layouts, partials
      view/                   helpers: form_for and form builder, tags, URLs,
                              assets, fragment cache, content_for, pagination
      helpers/                output safety (SafeString, escaping)
      middleware.rb           middleware stack builder
      middleware/             logger, session, static, assets, params,
                              compression, cors, rate_limiting
      server.rb               HTTP/1.1 and WebSocket server
      websocket.rb            WebSocket entry point
      websocket/              handshake, frame, connection, hub
      orm.rb                  connect, store, migrator, transaction
      orm/                    store, model, relation, query engine,
                              associations, validations, callbacks,
                              migrations, transactions, locking, encryption,
                              enums, dirty tracking, pagination, soft delete,
                              list positions, secure password/token,
                              token_for, nested attributes, serialization,
                              N+1 detection
      jobs.rb                 default queue
      jobs/                   job, queue, worker
      mailer.rb               delivery (test, SMTP)
      mailer/                 base, message, delivery, delivery job,
                              previews, preview app
      i18n.rb                 locale state and lookup API
      i18n/                   backend, translator
      cache.rb                in-memory cache store
      security.rb             security entry point
      security/               CSRF, cookie jar, message verifier,
                              message encryptor, strong parameters
      authenticatable.rb      authentication and remember-me sessions
      authorizable.rb         authorize / policy_scope
      policy.rb               policy and scope base classes
      rate_limiter.rb         throttles, blocklists, safelists, fail2ban
      rate_limiter/           memory and PStore stores
      cors.rb                 CORS rules
      assets.rb               asset manifest access
      assets/                 compiler, manifest
      instrumentation.rb      event bus and log subscriber
      cli.rb                  command line implementation
      testing.rb              test helpers entry point
      testing/                integration session, test module, response
      support/inflector.rb    underscore, camelize, pluralize, tableize
    examples/                 sample apps and demo scripts
    test/                     Minitest suite

## Limitations

- The store keeps each database in one `PStore` file and copies the tables
  on every transaction. It is meant for small applications and tests, not
  for large data sets or high write rates. There is no SQL adapter.
- The server starts one thread per connection, speaks plain HTTP/1.1 (no
  TLS, no HTTP/2), reads request bodies fully into memory, and does not
  accept chunked request bodies or enforce request size limits or timeouts.
  Put a reverse proxy in front of it for anything public.
- The template engine supports `<% %>`, `<%= %>`, `<%== %>` and `<%# %>`, but
  not ERB trim modes.
- WebSocket extensions such as `permessage-deflate` and subprotocols are not
  supported.
- SMTP delivery uses plain `Net::SMTP` settings; there is no STARTTLS option.
- Developed and tested on Ruby 3.3. `net-smtp` (SMTP delivery only) is a
  bundled gem, and newer Rubies move more of the standard library, such as
  `pstore`, from default to bundled gems. They are still installed with Ruby,
  but a Bundler-managed app has to list them in its Gemfile.

## License

MIT, see [LICENSE](LICENSE).
