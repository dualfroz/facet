# Examples

Two sample applications and a set of scripts that boot them on an ephemeral
port and drive them over real HTTP. Every script exits non-zero if something
it checks does not hold. Run them from anywhere with Ruby 3.3+:

    ruby examples/demo.rb
    ruby examples/blog_demo.rb

## Applications

| Path | What it is |
|---|---|
| `app.rb` | Small Sinatra-style app: routes, params, splat, groups, sessions, redirects, inline ERB. Run it directly to get a server. |
| `blog/` | Full application: models and migrations, controllers, views and layouts, mailers, policies, a WebSocket channel, assets, locales (`en`, `pl`) and seeds. `ruby examples/blog/bin/server 3000` starts it. |

The blog keeps its data in `examples/blog/db/*.pstore`. Set `FACET_BLOG_DB_DIR`
to point it at another directory; the scripts below that need a clean state do
this themselves and never touch `development.pstore`.

## Scripts

| Script | What it shows |
|---|---|
| `demo.rb` | `app.rb` over HTTP: path and query params, JSON echo, splat routes, route groups, a session counter cookie, a 301 redirect. |
| `blog_demo.rb` | The main end-to-end walk through the blog: sign-up with encrypted email, multipart upload, HTTP Range and conditional GET on static and fingerprinted files, comments, polymorphic likes, optimistic locking, enums, ETags, CORS, JSON:API errors, counter caches, nested attributes, pagination, index usage, gzip, background jobs, mailer previews, CSV import and export, list positions, authorization, remember-me devices, soft delete and the instrumentation log. Data stays on disk between runs. |
| `blog_email_confirmation_demo.rb` | Email confirmation: the link is mailed through the job queue after sign-up, the resend form does not reveal whether an address exists, changing the address invalidates the old token. |
| `blog_password_reset_demo.rb` | Forgot-password flow built on `generates_token_for`: the mailed link changes the password, the old password stops working, the token cannot be reused. |
| `blog_remember_sessions_demo.rb` | `max_remember_sessions: 3`: signing in on a fourth device prunes only the oldest remembered session. |
| `blog_giveaway_demo.rb` + `blog_giveaway_worker.rb` | `with_lock` under real concurrency: several independent server processes share one database and race for 3 giveaway slots; exactly 3 win. |
| `blog_rate_limit_persistence_demo.rb` + `blog_rate_limit_worker.rb` | `RateLimiter::PStoreStore`: a login throttle and a sign-up throttle tripped by one process are still enforced by a fresh process. |
| `blog_rotation_demo.rb` + `blog_rotation_worker.rb` | Encryption key rotation across process restarts: provision under key v1, log in with v2 plus v1 as fallback, retire v1; a user whose row was never re-saved is locked out cleanly. |
| `blog_session_secret_rotation_demo.rb` + `blog_session_secret_rotation_worker.rb` | Session secret rotation with `previous_secrets:`: a session written during the transition is re-signed and survives the cutover, an untouched one is logged out. |
| `blog_seed_demo.rb` | `bin/facet db:seed` run twice as a separate process (seeds are idempotent), then the seeded posts rendered over HTTP. |
| `blog_websocket_demo.rb` | The blog's WebSocket channel: raw-socket upgrade handshakes next to normal HTTP on one server, moderation actions broadcast to subscribers of one post only, message size limit and the connection cap. |
| `strict_n_plus_one_demo.rb` | N+1 detection on a small throwaway app: with `raise_on_violation: true` a regression becomes a normal 500 response, without it the request succeeds and the violation is logged. |

The `*_worker.rb` files are not meant to be run by hand; the matching demo
starts them as separate `ruby` processes.
