$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'zlib'
require 'stringio'
require 'csv'
require_relative 'examples/blog/app'

server = Prism::Server.new(Blog, port: 0).start
port = server.port
puts "blog demo server on port #{port}"
puts "database file: #{File.join(__dir__, 'examples/blog/db/development.pstore')}"
log_path = File.join(__dir__, 'examples/blog/log/development.log')
log_offset_before_requests = File.exist?(log_path) ? File.size(log_path) : 0
puts '-' * 40

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def cookie_value_from(response, name)
  lines = response.get_fields('set-cookie') || []
  line = lines.find { |l| l.start_with?("#{name}=") }
  line&.split(';')&.first
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

def multipart_body(boundary, fields:, files: {})
  parts = fields.map do |name, value|
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
  end
  parts += files.map do |name, (filename, content_type, content)|
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n" \
      "Content-Type: #{content_type}\r\n\r\n#{content}\r\n"
  end
  parts.join + "--#{boundary}--\r\n"
end

# Signs in as the writer from a brand new, entirely independent cookie jar
# (its own session cookie, its own CSRF token fetched fresh from the
# sign-in page) - a second real HTTP client would look exactly like this,
# unlike reusing the caller's own `cookie`/`token`. Returns the
# remember_session_token cookie this "browser" got back, proving
# Prism::Authenticatable's remember_sessions: hands out one independent
# LoginSession row per device instead of one shared column.
def sign_in_new_device(http, label, user_agent:)
  new_session_page = http.get('/session/new', 'User-Agent' => user_agent)
  device_cookie = cookie_from(new_session_page)
  device_token = csrf_token_from(new_session_page.body)
  body = URI.encode_www_form(
    'user[email]' => 'writer@example.com', 'user[password]' => 'correct horse battery staple',
    'user[remember_me]' => '1', 'authenticity_token' => device_token
  )
  signed_in = http.post('/session.json', body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                'Cookie' => device_cookie, 'User-Agent' => user_agent)
  raise "expected #{label} to sign in, got #{signed_in.code}" unless signed_in.code == '200'
  remember_cookie = cookie_value_from(signed_in, 'remember_session_token')
  raise "expected #{label}'s sign-in to set its own remember_session_token cookie" unless remember_cookie
  puts "  #{label} signed in from its own independent cookie jar -> #{signed_in.code}, own remember-me cookie set"
  remember_cookie
end

Net::HTTP.start('127.0.0.1', port) do |http|
  home = http.get('/')
  cookie = cookie_from(home)
  token = csrf_token_from(home.body)
  puts "GET / -> #{home.code} (session cookie set, csrf token captured)"

  css_href = home.body[/<link rel="stylesheet" href="([^"]+)">/, 1]
  js_src = home.body[/<script src="([^"]+)">/, 1]
  raise 'expected the layout to reference a fingerprinted stylesheet' unless css_href =~ %r{\A/assets/stylesheets/application-[0-9a-f]{8}\.css\z}
  raise 'expected the layout to reference a fingerprinted script' unless js_src =~ %r{\A/assets/javascripts/application-[0-9a-f]{8}\.js\z}

  css_response = http.get(css_href)
  js_response = http.get(js_src)
  manifest = JSON.parse(File.read(File.join(__dir__, 'examples/blog/public/assets/manifest.json')))
  unless css_response.code == '200' && css_response['cache-control'] == 'public, max-age=31536000, immutable'
    raise "expected the fingerprinted stylesheet to be served with a far-future Cache-Control, got #{css_response.code} #{css_response['cache-control'].inspect}"
  end
  unless manifest['stylesheets/application.css'] == css_href.delete_prefix('/assets/')
    raise 'expected the on-disk manifest.json to agree with the href the layout rendered'
  end
  puts "GET #{css_href} -> #{css_response.code}, Cache-Control=#{css_response['cache-control']}"
  puts "GET #{js_src} -> #{js_response.code} (Prism::Assets::Compiler fingerprinted both files, manifest.json on disk matches)"

  puts '-' * 40
  puts 'Conditional GET (Prism::StaticCache, RFC 7232/7233) against the fingerprinted stylesheet, over the ' \
       'real Prism::Server socket - Middleware::Assets hands out a STRONG ETag here (derived from the ' \
       'fingerprint hash already in the filename), the only place in this app where If-Range after an ETag can succeed'
  css_etag = css_response['etag']
  raise "expected a strong ETag (no W/ prefix) on the fingerprinted stylesheet, got #{css_etag.inspect}" if css_etag.nil? || css_etag.start_with?('W/')
  css_not_modified = http.get(css_href, 'If-None-Match' => css_etag)
  puts "GET #{css_href} with If-None-Match: #{css_etag} -> #{css_not_modified.code}"
  raise "expected 304 for a matching strong ETag, got #{css_not_modified.code}" unless css_not_modified.code == '304'
  raise 'a 304 must not carry a body' unless css_not_modified.body.to_s.empty?
  raise 'a 304 must not carry Content-Type (no entity, only validators)' if css_not_modified['content-type']

  css_range_honored = http.get(css_href, 'If-Range' => css_etag, 'Range' => 'bytes=0-3')
  puts "GET #{css_href} with If-Range: #{css_etag} (strong) + Range: bytes=0-3 -> #{css_range_honored.code}, " \
       "Content-Range=#{css_range_honored['content-range']}"
  unless css_range_honored.code == '206'
    raise "expected 206: If-Range with a matching STRONG ETag must honor Range, got #{css_range_honored.code}"
  end
  raise 'expected a bytes 0-3/<total> Content-Range' unless css_range_honored['content-range'] =~ %r{\Abytes 0-3/\d+\z}
  puts 'strong ETag -> 304 on a repeat GET and Range honored under If-Range, both through the real TCP socket'

  anonymous_attempt = http.post(
    '/posts', URI.encode_www_form('post[title]' => 'should be blocked', 'authenticity_token' => token),
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  puts "POST /posts while signed out -> #{anonymous_attempt.code} Location=#{anonymous_attempt['location']}"
  unless anonymous_attempt.code == '302' && anonymous_attempt['location'].to_s.end_with?('/session/new')
    raise "expected an anonymous post to be redirected to the sign-in page, got #{anonymous_attempt.code} " \
          "Location=#{anonymous_attempt['location']}"
  end

  signup_body = URI.encode_www_form(
    'user[email]' => 'writer@example.com', 'user[password]' => 'correct horse battery staple',
    'user[password_confirmation]' => 'correct horse battery staple', 'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST /users (sign up) -> #{signup.code} Location=#{signup['location']}"
  raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'
  signed_in_cookie = cookie_from(signup)
  cookie = signed_in_cookie unless signed_in_cookie.empty?

  # User#email is `encrypts :email, deterministic: true` - prove that is
  # real end to end, not just unit-tested: find_by(email:) still resolves
  # the plaintext through the real request cycle's created row, but what
  # actually landed on disk is ciphertext, not "writer@example.com".
  writer_user = User.find_by(email: 'writer@example.com')
  raise 'expected to find the newly signed-up user back by plaintext email (deterministic encryption)' unless writer_user
  writer_raw_row = Prism::Orm.store.find(:users, writer_user.id)
  if writer_raw_row['email'] == 'writer@example.com' || !writer_raw_row['email'].to_s.include?('--')
    raise "expected users.email to be stored encrypted at rest, got #{writer_raw_row['email'].inspect}"
  end
  puts "  users.email stored encrypted at rest (#{writer_raw_row['email'][0, 20]}...), decrypts back to #{writer_user.email}"

  boundary = '----PrismBlogDemoBoundary'
  body = multipart_body(
    boundary,
    fields: { 'post[title]' => 'Hello from Prism', 'post[body]' => 'This record was written through the ORM-lite file store.',
              'authenticity_token' => token },
    files: { 'post[cover]' => ['cover.txt', 'text/plain', 'not really an image, just bytes'] }
  )
  create = http.post(
    '/posts',
    body,
    'Content-Type' => "multipart/form-data; boundary=#{boundary}", 'Cookie' => cookie
  )
  post_path = create['location']
  puts "POST /posts (multipart, with cover + CSRF token) -> #{create.code} Location=#{post_path}"
  raise "expected a redirect to the new post, got #{create.code}" unless create.code == '302'
  # Every flash-touching response gets a fresh Set-Cookie (the whole
  # session, flash included, lives signed in the cookie - see
  # Prism::Middleware::Session#write_cookie), so it has to be captured
  # here too, not just after sign-in/sign-up/sign-out - otherwise the
  # edit/update scene below would keep reading the flash frozen into the
  # cookie from right after sign-up instead of the post's own notices.
  post_create_cookie = cookie_from(create)
  cookie = post_create_cookie unless post_create_cookie.empty?

  show = http.get(post_path, 'Cookie' => cookie)
  puts "GET #{post_path} -> #{show.code}"
  raise 'cover filename missing from show page' unless show.body.include?('/uploads/')
  post_id = post_path.split('/').last
  # posts#show is slug-keyed now (see app.rb's `param: :slug`), so post_id
  # above is really the post's SLUG - fine for building URLs (that's all
  # it's used for almost everywhere below), but Like.likeable_id is a real
  # numeric FK (see LikesController#find_likeable!, which does
  # klass.find(params['likeable_id'])), so the handful of places that POST
  # to /likes or query the Like table directly need this actual row id
  # instead, resolved once here since it never changes across the post's
  # own trash/restore cycle later in this script.
  post_row_id = Post.find_by!(slug: post_id).id
  cover_path = show.body[%r{/uploads/([^"']+)}, 0]
  cover_file = File.join(__dir__, 'examples/blog/public', cover_path)
  raise "uploaded cover file missing on disk: #{cover_file}" unless File.exist?(cover_file)

  puts '-' * 40
  puts 'HTTP Range requests against the uploaded cover (Prism::HttpRange, RFC 7233), served by ' \
       'Middleware::Static over the real Prism::Server socket - not just .call(env) in a unit test'
  cover_size = File.size(cover_file)
  full = http.get(cover_path, 'Cookie' => cookie)
  puts "GET #{cover_path} (no Range) -> #{full.code}, Accept-Ranges=#{full['accept-ranges']}, " \
       "Content-Length=#{full['content-length']}"
  raise "expected 200 with the whole cover, got #{full.code}" unless full.code == '200'
  raise 'expected Accept-Ranges: bytes on an ordinary 200' unless full['accept-ranges'] == 'bytes'
  raise 'expected the full cover body on a plain GET' unless full.body.bytesize == cover_size

  prefix = http.get(cover_path, 'Cookie' => cookie, 'Range' => 'bytes=0-2')
  puts "GET #{cover_path} (Range: bytes=0-2) -> #{prefix.code}, Content-Range=#{prefix['content-range']}, " \
       "body=#{prefix.body.inspect}"
  raise "expected 206 for a satisfiable prefix range, got #{prefix.code}" unless prefix.code == '206'
  raise "expected Content-Range bytes 0-2/#{cover_size}" unless prefix['content-range'] == "bytes 0-2/#{cover_size}"
  raise "expected only the first 3 bytes on disk, got #{prefix.body.inspect}" unless prefix.body == 'not'

  suffix = http.get(cover_path, 'Cookie' => cookie, 'Range' => 'bytes=-5')
  puts "GET #{cover_path} (Range: bytes=-5) -> #{suffix.code}, Content-Range=#{suffix['content-range']}, " \
       "body=#{suffix.body.inspect}"
  raise "expected 206 for a satisfiable suffix range, got #{suffix.code}" unless suffix.code == '206'
  raise "expected the last 5 bytes actually read off disk, got #{suffix.body.inspect}" unless suffix.body == 'bytes'

  unsatisfiable = http.get(cover_path, 'Cookie' => cookie, 'Range' => "bytes=#{cover_size + 100}-#{cover_size + 200}")
  puts "GET #{cover_path} (Range: bytes=#{cover_size + 100}-#{cover_size + 200}, beyond EOF) -> " \
       "#{unsatisfiable.code}, Content-Range=#{unsatisfiable['content-range']}"
  raise "expected 416 for a range starting past EOF, got #{unsatisfiable.code}" unless unsatisfiable.code == '416'
  unless unsatisfiable['content-range'] == "bytes */#{cover_size}"
    raise "expected Content-Range: bytes */#{cover_size} on 416, got #{unsatisfiable['content-range'].inspect}"
  end
  puts "cover (#{cover_size} bytes) served correctly whole, as a 3-byte prefix, a 5-byte suffix, and rejected " \
       'with 416 for an out-of-range request - all through the real TCP socket, not a direct middleware call'

  puts '-' * 40
  puts 'Conditional GET against the SAME cover file (Middleware::Static hands out only a cheap WEAK ETag - ' \
       'size+mtime, no fingerprint - unlike the CSS scene above), over the real socket'
  cover_etag = full['etag']
  raise "expected a weak ETag (W/ prefix) on a plain static file, got #{cover_etag.inspect}" unless cover_etag&.start_with?('W/')
  cover_not_modified = http.get(cover_path, 'Cookie' => cookie, 'If-None-Match' => cover_etag)
  puts "GET #{cover_path} with If-None-Match: #{cover_etag} -> #{cover_not_modified.code}"
  raise "expected 304 for a matching weak ETag, got #{cover_not_modified.code}" unless cover_not_modified.code == '304'
  unless [nil, '0'].include?(cover_not_modified['content-length'])
    raise "expected an empty (or absent) Content-Length on a 304, got #{cover_not_modified['content-length'].inspect}"
  end

  cover_range_falls_back = http.get(cover_path, 'Cookie' => cookie, 'If-Range' => cover_etag, 'Range' => 'bytes=0-2')
  puts "GET #{cover_path} with If-Range: #{cover_etag} (weak) + Range: bytes=0-2 -> #{cover_range_falls_back.code} " \
       '(RFC 7232 SS2.3.2: If-Range never honors a weak validator, so this must fall back to the full body)'
  unless cover_range_falls_back.code == '200'
    raise "expected 200 (Range ignored): a weak ETag can never satisfy If-Range, got #{cover_range_falls_back.code}"
  end
  raise 'expected the FULL cover body once If-Range falls back' unless cover_range_falls_back.body.bytesize == cover_size
  puts 'weak ETag -> 304 on a repeat GET, but If-Range on that same weak ETag correctly falls back to a full 200 ' \
       '(the asymmetry Prism::StaticCache exists to get right)'

  comment_body = URI.encode_www_form(
    'comment[author]' => 'A reader', 'comment[body]' => 'Nice post!', 'authenticity_token' => token
  )
  comment = http.post(
    "/posts/#{post_id}/comments", comment_body,
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  puts "POST /posts/#{post_id}/comments -> #{comment.code} Location=#{comment['location']}"

  show_with_comment = http.get(post_path, 'Cookie' => cookie)
  raise 'comment did not show up on the post page' unless show_with_comment.body.include?('Nice post!')
  puts "GET #{post_path} -> comment thread now includes the new comment"

  comment_id = show_with_comment.body[/id="comment-(\d+)"/, 1]
  raise 'could not find the new comment id on the post page' unless comment_id
  comment_edit_path = "/posts/#{post_id}/comments/#{comment_id}"

  puts '-' * 40
  puts 'liking the post and one of its comments (polymorphic Like: belongs_to :likeable, polymorphic: true)'
  like_post = http.post("/likes?likeable_type=Post&likeable_id=#{post_row_id}",
                         URI.encode_www_form('authenticity_token' => token),
                         'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST /likes?likeable_type=Post&likeable_id=#{post_row_id} -> #{like_post.code} Location=#{like_post['location']}"
  raise "expected liking the post to redirect, got #{like_post.code}" unless like_post.code == '302'
  like_post_cookie = cookie_from(like_post)
  cookie = like_post_cookie unless like_post_cookie.empty?
  raise 'Post#likes (as: :likeable) should report exactly 1 like' unless Post.find_by!(slug: post_id).likes.count == 1
  unless Post.find_by!(slug: post_id).likes_count == 1
    raise 'belongs_to :likeable, counter_cache: true should have bumped Post#likes_count to 1 on Like#create'
  end

  show_with_like = http.get(post_path, 'Cookie' => cookie)
  unless show_with_like.body.include?('1 like') || show_with_like.body.include?('Polubienia: 1')
    raise 'post page should render the updated like count'
  end
  puts "GET #{post_path} -> like count rendered (ApplicationController#likes_count now reads the " \
       "counter_cache column, not record.likes.count), Unlike button now shown"

  like_comment = http.post("/likes?likeable_type=Comment&likeable_id=#{comment_id}",
                            URI.encode_www_form('authenticity_token' => token),
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected liking the comment to redirect, got #{like_comment.code}" unless like_comment.code == '302'
  like_comment_cookie = cookie_from(like_comment)
  cookie = like_comment_cookie unless like_comment_cookie.empty?
  raise 'Comment#likes (as: :likeable) should report exactly 1 like' unless Comment.find(comment_id).likes.count == 1
  unless Comment.find(comment_id).likes_count == 1
    raise 'polymorphic counter_cache should also bump Comment#likes_count, same Like model/column default'
  end
  puts "POST /likes?likeable_type=Comment&likeable_id=#{comment_id} -> #{like_comment.code} (comment liked too, " \
       "same Like model and controller action as the post)"

  duplicate_like = http.post("/likes?likeable_type=Post&likeable_id=#{post_row_id}",
                              URI.encode_www_form('authenticity_token' => token),
                              'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless duplicate_like.code == '302'
    raise "expected a same-user duplicate like to still just redirect quietly, got #{duplicate_like.code}"
  end
  raise 'validates_uniqueness_of scope: should have silently rejected the duplicate like' unless Post.find_by!(slug: post_id).likes.count == 1
  unless Post.find_by!(slug: post_id).likes_count == 1
    raise 'a rejected duplicate like (failed validation, no Like row created) must not bump likes_count'
  end
  puts "POST /likes?likeable_type=Post&likeable_id=#{post_row_id} again -> #{duplicate_like.code} " \
       "(uniqueness scope: [:likeable_id, :likeable_type] rejected the duplicate, still 1 like)"

  own_like_id = Post.find_by!(slug: post_id).likes.first.id
  unlike = http.post("/likes/#{own_like_id}", URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token),
                      'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected unliking the post to redirect, got #{unlike.code}" unless unlike.code == '302'
  unlike_cookie = cookie_from(unlike)
  cookie = unlike_cookie unless unlike_cookie.empty?
  raise 'Post#likes should be back to zero after unliking' unless Post.find_by!(slug: post_id).likes.count.zero?
  unless Post.find_by!(slug: post_id).likes_count.zero?
    raise 'unliking (really_destroy! per LikesController#destroy) should have decremented likes_count back to 0'
  end
  puts "POST /likes/#{own_like_id} with _method=DELETE -> #{unlike.code} (unliked, count back to 0)"

  relike = http.post("/likes?likeable_type=Post&likeable_id=#{post_row_id}",
                      URI.encode_www_form('authenticity_token' => token),
                      'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected re-liking the post to redirect, got #{relike.code}" unless relike.code == '302'
  relike_cookie = cookie_from(relike)
  cookie = relike_cookie unless relike_cookie.empty?
  puts "POST /likes?likeable_type=Post&likeable_id=#{post_row_id} -> #{relike.code} " \
       "(re-liked so the dependent :destroy cascade below has something to prove)"

  comment_edit_page = http.get("#{comment_edit_path}/edit", 'Cookie' => cookie)
  puts "GET #{comment_edit_path}/edit -> #{comment_edit_page.code}"
  raise 'comment edit form should be pre-filled with the current body' unless comment_edit_page.body.include?('Nice post!')

  comment_update_body = URI.encode_www_form('comment[body]' => 'Nice post, edited!', '_method' => 'PATCH',
                                             'authenticity_token' => token)
  comment_update = http.post(comment_edit_path, comment_update_body,
                              'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{comment_edit_path} with _method=PATCH -> #{comment_update.code} Location=#{comment_update['location']}"
  raise "expected the comment update to redirect back to the post, got #{comment_update.code}" unless comment_update.code == '302'
  comment_update_cookie = cookie_from(comment_update)
  cookie = comment_update_cookie unless comment_update_cookie.empty?

  show_with_edited_comment = http.get(post_path, 'Cookie' => cookie)
  raise 'edited comment body did not appear on the show page' unless show_with_edited_comment.body.include?('Nice post, edited!')
  unless show_with_edited_comment.body.include?('changed: body') || show_with_edited_comment.body.include?('zmienione: body')
    raise 'Comment#saved_changes-backed notice should name body as the changed field'
  end
  puts "GET #{post_path} -> comment body updated, dirty-tracking notice named the changed field"

  comment_noop_body = URI.encode_www_form('comment[body]' => 'Nice post, edited!', '_method' => 'PATCH',
                                           'authenticity_token' => token)
  comment_noop = http.post(comment_edit_path, comment_noop_body,
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the no-op comment update to redirect too, got #{comment_noop.code}" unless comment_noop.code == '302'
  comment_noop_cookie = cookie_from(comment_noop)
  cookie = comment_noop_cookie unless comment_noop_cookie.empty?
  comment_noop_show = http.get(post_path, 'Cookie' => cookie)
  unless comment_noop_show.body.include?('Nothing changed') || comment_noop_show.body.include?('Nic sie nie zmienilo')
    raise 'submitting an identical comment body should report that zero fields actually changed'
  end
  puts "POST #{comment_edit_path} with identical body -> Comment#saved_changes was empty, notice said nothing changed"

  # Prism::Orm::Locking on Comment: same "two browser tabs" scenario as the
  # Post edit above, proving the mechanism (auto-detected via the
  # add_lock_version_to_comments migration, zero model code) works
  # identically for a second model, not just the one it was built against.
  comment_tab_a_edit = http.get("#{comment_edit_path}/edit", 'Cookie' => cookie)
  comment_tab_b_edit = http.get("#{comment_edit_path}/edit", 'Cookie' => cookie)
  comment_tab_a_lock_version = comment_tab_a_edit.body[/name="comment\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  comment_tab_b_lock_version = comment_tab_b_edit.body[/name="comment\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  raise 'comment edit form should carry the current lock_version in a hidden field' if comment_tab_a_lock_version.to_s.empty?
  unless comment_tab_a_lock_version == comment_tab_b_lock_version
    raise 'both comment tabs should have observed the same lock_version before either saved'
  end

  comment_tab_a_save_body = URI.encode_www_form(
    'comment[body]' => 'Nice post, tab A won!', 'comment[lock_version]' => comment_tab_a_lock_version,
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  comment_tab_a_save = http.post(comment_edit_path, comment_tab_a_save_body,
                                  'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected comment tab A's save to succeed, got #{comment_tab_a_save.code}" unless comment_tab_a_save.code == '302'
  comment_tab_a_cookie = cookie_from(comment_tab_a_save)
  cookie = comment_tab_a_cookie unless comment_tab_a_cookie.empty?
  puts "POST #{comment_edit_path} tab A (lock_version=#{comment_tab_a_lock_version}) -> #{comment_tab_a_save.code}, saved first"

  comment_tab_b_save_body = URI.encode_www_form(
    'comment[body]' => 'Nice post, tab B lost!', 'comment[lock_version]' => comment_tab_b_lock_version,
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  comment_tab_b_save = http.post(comment_edit_path, comment_tab_b_save_body,
                                  'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless comment_tab_b_save.code == '409'
    raise "expected comment tab B's stale save to be rejected with 409, got #{comment_tab_b_save.code}"
  end
  unless comment_tab_b_save.body.include?('Someone else changed this comment') ||
         comment_tab_b_save.body.include?('Ktos inny zmienil ten komentarz')
    raise 'the 409 response should render the comment stale-conflict notice'
  end
  puts "POST #{comment_edit_path} tab B (stale lock_version=#{comment_tab_b_lock_version}) -> " \
       "#{comment_tab_b_save.code} (expected 409, StaleObjectError caught)"

  after_comment_conflict = http.get(post_path, 'Cookie' => cookie)
  unless after_comment_conflict.body.include?('Nice post, tab A won!')
    raise "tab B's rejected comment write must not have overwritten tab A's body"
  end
  raise "tab B's rejected comment write must not have leaked through" if after_comment_conflict.body.include?('tab B lost')
  puts "GET #{post_path} -> tab A's comment body survives untouched, Prism::Orm::Locking prevented the lost update"

  # Comment's enum :status defaults every new comment to "pending" (column
  # default 0), so this comment - created way back before this feature
  # existed in the script - is STILL pending right now. The moderation
  # visibility scene further below (reader2, then an anonymous visitor)
  # depends on it already being approved by the time they look, same as
  # any real moderator would approve a comment before strangers see it.
  raise "the pending badge should show for the comment's own author before it's approved" unless after_comment_conflict.body.include?('Pending approval')
  approve_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  approve_comment = http.post("#{comment_edit_path}/approve", approve_body,
                               'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the comment approval to redirect, got #{approve_comment.code}" unless approve_comment.code == '302'
  approve_comment_cookie = cookie_from(approve_comment)
  cookie = approve_comment_cookie unless approve_comment_cookie.empty?
  approved_show = http.get(post_path, 'Cookie' => cookie)
  raise 'an approved comment should no longer show the pending badge' if approved_show.body.include?('Pending approval')
  puts "POST #{comment_edit_path}/approve -> #{approve_comment.code} (Comment#status: pending -> approved, " \
       'Comment enum :status + CommentPolicy#approve? checked the POST owner, not the comment author)'

  fresh_show = http.get(post_path, 'Cookie' => cookie)
  etag = fresh_show['etag']
  raise 'posts#show should set an ETag now that it uses fresh_when' unless etag
  puts "GET #{post_path} -> #{fresh_show.code}, ETag=#{etag}"

  conditional_show = http.get(post_path, 'Cookie' => cookie, 'If-None-Match' => etag)
  puts "GET #{post_path} with If-None-Match: #{etag} -> #{conditional_show.code}"
  raise "expected a fresh conditional GET to return 304, got #{conditional_show.code}" unless conditional_show.code == '304'
  raise '304 response must not carry a body' unless conditional_show.body.to_s.empty?

  second_comment_body = URI.encode_www_form(
    'comment[author]' => 'Another reader', 'comment[body]' => 'Me too!', 'authenticity_token' => token
  )
  second_comment = http.post("/posts/#{post_id}/comments", second_comment_body,
                              'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the second comment to redirect, got #{second_comment.code}" unless second_comment.code == '302'
  second_comment_cookie = cookie_from(second_comment)
  cookie = second_comment_cookie unless second_comment_cookie.empty?

  now_stale = http.get(post_path, 'Cookie' => cookie, 'If-None-Match' => etag)
  puts "GET #{post_path} with the OLD If-None-Match after a new comment -> #{now_stale.code}"
  unless now_stale.code == '200' && now_stale.body.include?('Me too!')
    raise "expected the stale ETag to be rejected and the fresh page (with the new comment) rendered, got #{now_stale.code}"
  end
  raise 'the fresh render must carry a NEW ETag, not the stale one' if now_stale['etag'] == etag
  puts "GET #{post_path} -> #{now_stale.code} (ETag changed after a comment was added, Prism::ConditionalGet is content-aware)"

  json_index = http.get('/posts.json')
  puts "GET /posts.json -> #{json_index.code} #{json_index['content-type']}"
  parsed = JSON.parse(json_index.body)
  raise 'json index did not include the new post' unless parsed.any? { |row| row['title'] == 'Hello from Prism' }

  puts '-' * 40
  puts 'CORS: Prism::Middleware::Cors + Prism::Cors, matched against the .json API surface only - a ' \
       'public read-only rule for any origin, and a credentialed read/write rule for one trusted admin origin'

  public_client_origin = 'https://blog-widget.example.net'
  cors_public_get = http.get('/posts.json', 'Origin' => public_client_origin)
  unless cors_public_get.code == '200' && cors_public_get['access-control-allow-origin'] == public_client_origin
    raise "expected a public GET /posts.json to echo Access-Control-Allow-Origin: #{public_client_origin}, " \
          "got #{cors_public_get['access-control-allow-origin'].inspect}"
  end
  if cors_public_get['access-control-allow-credentials']
    raise 'a public (non-credentialed) CORS resource must not set Access-Control-Allow-Credentials'
  end
  puts "GET /posts.json with Origin: #{public_client_origin} -> #{cors_public_get.code}, " \
       "Access-Control-Allow-Origin=#{cors_public_get['access-control-allow-origin']} (any origin can read)"

  cors_public_write_preflight = http.options('/posts', 'Origin' => public_client_origin,
                                                         'Access-Control-Request-Method' => 'POST')
  unless cors_public_write_preflight.code == '403'
    raise "expected the public origin's write preflight to be rejected, got #{cors_public_write_preflight.code}"
  end
  puts "OPTIONS /posts (preflight for POST) with Origin: #{public_client_origin} -> " \
       "#{cors_public_write_preflight.code} (the public rule only allows GET, POST is refused before it " \
       'ever reaches the router)'

  admin_origin = 'https://admin.blog-demo.internal'
  cors_admin_preflight = http.options('/posts', 'Origin' => admin_origin,
                                                 'Access-Control-Request-Method' => 'POST',
                                                 'Access-Control-Request-Headers' => 'Content-Type, X-CSRF-Token')
  unless cors_admin_preflight.code == '204' && cors_admin_preflight['access-control-allow-credentials'] == 'true'
    raise "expected the trusted admin origin's preflight to succeed with credentials allowed, got " \
          "#{cors_admin_preflight.code}"
  end
  unless cors_admin_preflight['access-control-allow-methods'].to_s.include?('POST')
    raise 'expected the preflight response to advertise POST among the allowed methods'
  end
  puts "OPTIONS /posts (preflight for POST) with Origin: #{admin_origin} -> #{cors_admin_preflight.code}, " \
       "Allow-Methods=#{cors_admin_preflight['access-control-allow-methods']}, Allow-Credentials=true " \
       '(a second, more privileged CORS rule for the trusted admin dashboard origin)'

  cors_unrelated_path = http.get('/', 'Origin' => public_client_origin)
  if cors_unrelated_path['access-control-allow-origin']
    raise 'a path with no configured CORS resource must not carry any Access-Control-* headers, even with ' \
          'an Origin header present'
  end
  puts "GET / with Origin: #{public_client_origin} -> #{cors_unrelated_path.code}, no Access-Control-* " \
       'headers (the homepage is not a registered CORS resource, so the middleware passes it straight through)'

  puts '-' * 40
  puts 'JSON:API-lite validation/conflict errors (Prism::Orm::Errors#to_jsonapi + ' \
       'Renderable#render_errors) - PostsController#create/#update now respond_to format.json ' \
       'on both the happy and the failure path, not just posts#index'
  json_create_body = URI.encode_www_form(
    'post[title]' => 'JSON API post', 'post[body]' => 'Created via the .json format.',
    'authenticity_token' => token
  )
  json_create = http.post('/posts.json', json_create_body,
                           'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected creating a post via .json to return 201, got #{json_create.code}" unless json_create.code == '201'
  created_via_json = JSON.parse(json_create.body)
  json_post_id = created_via_json['id']
  # posts#create/#index/#update .json bodies now carry `slug` alongside
  # `id` (see PostsController) - a JSON client has no other way to build
  # a valid /posts/:slug URL for a post it just created, now that show/
  # update/destroy are slug-keyed (see app.rb's `param: :slug`).
  json_post_slug = created_via_json['slug']
  raise 'json create response should echo the saved title' unless created_via_json['title'] == 'JSON API post'
  raise 'json create response should carry the generated slug' if json_post_slug.to_s.empty?
  puts "POST /posts.json -> #{json_create.code}, created post #{json_post_id} as a JSON payload (no redirect)"

  json_create_cookie = cookie_from(json_create)
  cookie = json_create_cookie unless json_create_cookie.empty?

  invalid_json_create_body = URI.encode_www_form(
    'post[title]' => '', 'post[body]' => '', 'authenticity_token' => token
  )
  invalid_json_create = http.post('/posts.json', invalid_json_create_body,
                                   'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless invalid_json_create.code == '422'
    raise "expected a blank title via .json to fail with 422, got #{invalid_json_create.code}"
  end
  invalid_create_errors = JSON.parse(invalid_json_create.body)['errors']
  unless invalid_create_errors.is_a?(Array) && invalid_create_errors.any? { |e| e['source']['pointer'] == '/data/attributes/title' }
    raise "expected a JSON:API error object pointing at /data/attributes/title, got #{invalid_json_create.body}"
  end
  raise 'every JSON:API error object should carry the response status as a string' unless invalid_create_errors.all? { |e| e['status'] == '422' }
  puts "POST /posts.json with a blank title -> #{invalid_json_create.code}, " \
       "errors[0].source.pointer=#{invalid_create_errors.first['source']['pointer']}"

  json_update_body = URI.encode_www_form(
    'post[title]' => 'JSON API post (edited)', 'post[body]' => 'Updated via the .json format.',
    'post[lock_version]' => '0', '_method' => 'PATCH', 'authenticity_token' => token
  )
  json_update = http.post("/posts/#{json_post_slug}.json", json_update_body,
                           'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected updating a post via .json to return 200, got #{json_update.code}" unless json_update.code == '200'
  updated_via_json = JSON.parse(json_update.body)
  raise 'json update response should reflect the new title' unless updated_via_json['title'] == 'JSON API post (edited)'
  puts "PATCH /posts/#{json_post_slug}.json -> #{json_update.code}, title is now '#{updated_via_json['title']}'"

  json_update_cookie = cookie_from(json_update)
  cookie = json_update_cookie unless json_update_cookie.empty?

  stale_json_update_body = URI.encode_www_form(
    'post[title]' => 'stale attempt', 'post[body]' => 'this must be rejected',
    'post[lock_version]' => '0', '_method' => 'PATCH', 'authenticity_token' => token
  )
  stale_json_update = http.post("/posts/#{json_post_slug}.json", stale_json_update_body,
                                 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless stale_json_update.code == '409'
    raise "expected a stale lock_version via .json to be rejected with 409, got #{stale_json_update.code}"
  end
  stale_update_errors = JSON.parse(stale_json_update.body)['errors']
  unless stale_update_errors.is_a?(Array) && stale_update_errors.first['source']['pointer'] == '/data/attributes/lock_version'
    raise "expected the 409 body to be a JSON:API error pointing at lock_version, got #{stale_json_update.body}"
  end
  puts "PATCH /posts/#{json_post_slug}.json with a stale lock_version -> #{stale_json_update.code} " \
       "(StaleObjectError still caught, now with a JSON:API error body instead of a re-rendered form)"

  # 'no-such-post-slug', not a bare number - posts#show is slug-keyed now
  # (see app.rb's `param: :slug`), so this exercises the SAME "no row
  # matches" 404 path a real mistyped/stale URL would hit.
  missing_html = http.get('/posts/no-such-post-slug', 'Cookie' => cookie)
  puts "GET /posts/no-such-post-slug (HTML) -> #{missing_html.code} #{missing_html['content-type']}"
  raise "expected a plain-text/HTML 404 for a missing post, got #{missing_html.code}" unless missing_html.code == '404'
  raise 'an HTML-format 404 must not be a JSON:API error body' if missing_html.body.strip.start_with?('{')

  missing_json = http.get('/posts/no-such-post-slug.json', 'Cookie' => cookie)
  puts "GET /posts/no-such-post-slug.json -> #{missing_json.code} #{missing_json['content-type']}"
  raise "expected a JSON:API 404 for a missing post via .json, got #{missing_json.code}" unless missing_json.code == '404'
  missing_errors = JSON.parse(missing_json.body)['errors']
  unless missing_errors.is_a?(Array) && missing_errors.size == 1 && missing_errors.first['status'] == '404'
    raise "expected a single JSON:API error object with status 404, got #{missing_json.body}"
  end
  raise 'a 404 JSON:API error has no single attribute to point at, so source must be absent' if missing_errors.first.key?('source')
  puts "GET /posts/no-such-post-slug.json -> #{missing_json.code}, errors[0]={status: #{missing_errors.first['status'].inspect}, " \
       "detail: #{missing_errors.first['detail'].inspect}} (respond_not_found: same JSON:API shape as render_errors, no source.pointer)"

  puts '-' * 40
  puts 'Comment belongs_to :post, counter_cache: true - posts#index reads post.comments_count, ' \
       'a plain column, instead of running a query per post to count its comments'
  home_with_two_comments = http.get('/', 'Cookie' => cookie)
  unless home_with_two_comments.body.include?('2 comment(s)')
    raise "expected the index listing to show the counter-cached total of 2 comments, body was: " \
          "#{home_with_two_comments.body[/<li class="post".*?<\/li>/m]}"
  end
  puts "GET / -> post listing shows '2 comment(s)' (Post#comments_count bumped twice by Comment's after_create hook)"

  second_comment_id = now_stale.body.scan(/id="comment-(\d+)"/).flatten.first
  raise 'could not find the second comment id (newest-first ordering) on the post page' unless second_comment_id
  second_comment_delete_path = "/posts/#{post_id}/comments/#{second_comment_id}"
  second_comment_destroy = http.post(
    second_comment_delete_path, URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token),
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  unless second_comment_destroy.code == '302'
    raise "expected destroying the second comment to redirect, got #{second_comment_destroy.code}"
  end
  destroy_comment_cookie = cookie_from(second_comment_destroy)
  cookie = destroy_comment_cookie unless destroy_comment_cookie.empty?
  puts "POST #{second_comment_delete_path} with _method=DELETE -> #{second_comment_destroy.code}"

  home_with_one_comment = http.get('/', 'Cookie' => cookie)
  unless home_with_one_comment.body.include?('1 comment(s)')
    raise 'expected the index listing to show comments_count back down to 1 after destroying a comment'
  end
  raise 'stale 2-comment count must not still be showing' if home_with_one_comment.body.include?('2 comment(s)')
  puts "GET / -> post listing shows '1 comment(s)' (Comment#destroy decremented Post#comments_count back down)"

  polish = http.get('/?locale=pl')
  raise 'locale switch did not translate the tagline' unless polish.body.include?('Maly blog')
  puts 'GET /?locale=pl -> tagline rendered in Polish'

  edit_page = http.get("#{post_path}/edit", 'Cookie' => cookie)
  puts "GET #{post_path}/edit -> #{edit_page.code}"
  raise 'edit form should be pre-filled with the current title' unless edit_page.body.include?('value="Hello from Prism"')

  puts '-' * 40
  puts 'PostsController#preview - diffs a proposed edit against the saved row without persisting it, ' \
       'using Prism::Orm::Dirty#restore_attributes to revert its Post instance so the SAME response can ' \
       'still show the actual saved title alongside the proposed one'
  preview_lock_version = edit_page.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  raise 'edit form should carry the current lock_version for the preview scene' if preview_lock_version.to_s.empty?
  preview_attempt_body = URI.encode_www_form(
    'post[title]' => 'Previewed title, not yet saved', 'post[body]' => 'Previewed body, not yet saved.',
    'post[lock_version]' => preview_lock_version, '_method' => 'PATCH', 'authenticity_token' => token
  )
  preview = http.post("#{post_path}/preview", preview_attempt_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{post_path}/preview with _method=PATCH -> #{preview.code}"
  raise "expected the preview action to render 200, got #{preview.code}" unless preview.code == '200'
  unless preview.body.include?('Previewed title, not yet saved')
    raise 'preview response should show the proposed title in the diff table'
  end
  unless preview.body.include?('Hello from Prism')
    raise "preview response should still show the post's actual saved title - " \
          "Post#restore_attributes should have reverted the in-memory change before rendering"
  end
  puts "POST #{post_path}/preview -> #{preview.code}, response shows both the proposed title (diff) and the " \
       "still-saved current title (restore_attributes reverted the model instance within the same request)"

  not_yet_saved = http.get(post_path, 'Cookie' => cookie)
  raise 'the previewed title must never have been persisted' if not_yet_saved.body.include?('Previewed title, not yet saved')
  puts "GET #{post_path} -> the previewed title was never written to disk, only diffed"

  update_body = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (edited)', 'post[body]' => 'Updated through a dirty-tracked update.',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  update = http.post(post_path, update_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{post_path} with _method=PATCH -> #{update.code} Location=#{update['location']}"
  raise "expected the update to redirect back to the post, got #{update.code}" unless update.code == '302'
  post_update_cookie = cookie_from(update)
  cookie = post_update_cookie unless post_update_cookie.empty?

  updated_show = http.get(post_path, 'Cookie' => cookie)
  raise 'updated title did not appear on the show page' unless updated_show.body.include?('Hello from Prism (edited)')
  unless updated_show.body.include?('changed: title, body') || updated_show.body.include?('zmienione: title, body')
    raise 'Prism::Orm::Dirty-backed notice should list the fields that actually changed'
  end
  puts "GET #{post_path} -> title/body updated, dirty-tracking notice named the changed fields"

  noop_body = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (edited)', 'post[body]' => 'Updated through a dirty-tracked update.',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  noop = http.post(post_path, noop_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the no-op update to redirect too, got #{noop.code}" unless noop.code == '302'
  noop_cookie = cookie_from(noop)
  cookie = noop_cookie unless noop_cookie.empty?
  noop_show = http.get(post_path, 'Cookie' => cookie)
  unless noop_show.body.include?('Nothing changed') || noop_show.body.include?('Nic sie nie zmienilo')
    raise 'submitting identical values should report that Prism::Orm::Dirty saw zero real changes'
  end
  puts "POST #{post_path} with identical values -> Post#saved_changes was empty, notice said nothing changed"

  # Prism::Orm::Locking: two "browser tabs" open the same edit form (each
  # capturing the lock_version the row had at that moment), tab A saves
  # first and bumps it, then tab B - still holding the OLD lock_version in
  # its hidden field - submits on top of that. Store#update's version check
  # runs inside the same PStore transaction as the merge, so tab B's write
  # cannot silently clobber tab A's: it must come back as a 409 with the
  # conflict notice, and tab A's title must survive untouched.
  tab_a_edit = http.get("#{post_path}/edit", 'Cookie' => cookie)
  tab_b_edit = http.get("#{post_path}/edit", 'Cookie' => cookie)
  tab_a_lock_version = tab_a_edit.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  tab_b_lock_version = tab_b_edit.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  raise 'edit form should carry the current lock_version in a hidden field' if tab_a_lock_version.to_s.empty?
  raise 'both tabs should have observed the same lock_version before either saved' unless tab_a_lock_version == tab_b_lock_version

  tab_a_save_body = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (tab A won)', 'post[body]' => 'Saved first.',
    'post[lock_version]' => tab_a_lock_version, '_method' => 'PATCH', 'authenticity_token' => token
  )
  tab_a_save = http.post(post_path, tab_a_save_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected tab A's save to succeed, got #{tab_a_save.code}" unless tab_a_save.code == '302'
  tab_a_cookie = cookie_from(tab_a_save)
  cookie = tab_a_cookie unless tab_a_cookie.empty?
  puts "POST #{post_path}/edit tab A (lock_version=#{tab_a_lock_version}) -> #{tab_a_save.code}, saved first"

  tab_b_save_body = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (tab B lost)', 'post[body]' => 'Submitted stale, should be rejected.',
    'post[lock_version]' => tab_b_lock_version, '_method' => 'PATCH', 'authenticity_token' => token
  )
  tab_b_save = http.post(post_path, tab_b_save_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless tab_b_save.code == '409'
    raise "expected tab B's stale save to be rejected with 409, got #{tab_b_save.code}"
  end
  unless tab_b_save.body.include?('Someone else changed this post') || tab_b_save.body.include?('Ktos inny zmienil ten wpis')
    raise 'the 409 response should render the stale-conflict notice'
  end
  puts "POST #{post_path}/edit tab B (stale lock_version=#{tab_b_lock_version}) -> #{tab_b_save.code} (expected 409, StaleObjectError caught)"

  after_conflict = http.get(post_path, 'Cookie' => cookie)
  raise "tab B's rejected write must not have overwritten tab A's title" unless after_conflict.body.include?('Hello from Prism (tab A won)')
  raise "tab B's rejected write must not have leaked through" if after_conflict.body.include?('tab B lost')
  puts "GET #{post_path} -> tab A's title survives untouched, Prism::Orm::Locking prevented the lost update"

  puts '-' * 40
  puts 'Post.accepts_nested_attributes_for :comments - the author moderates a comment from the POST edit form ' \
       'itself, not that comment\'s own /comments/:id route'
  moderation_comment_body = URI.encode_www_form(
    'comment[author]' => 'Someone to moderate', 'comment[body]' => 'unmoderated text', 'authenticity_token' => token
  )
  moderation_comment = http.post("/posts/#{post_id}/comments", moderation_comment_body,
                                  'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the extra comment to redirect, got #{moderation_comment.code}" unless moderation_comment.code == '302'
  moderation_comment_cookie = cookie_from(moderation_comment)
  cookie = moderation_comment_cookie unless moderation_comment_cookie.empty?

  before_moderation_home = http.get('/', 'Cookie' => cookie)
  unless before_moderation_home.body.include?('2 comment(s)')
    raise 'expected comments_count to read 2 before the moderation scene (the tab-A comment plus this new one)'
  end
  puts "POST /posts/#{post_id}/comments -> #{moderation_comment.code} (a second comment to moderate through the post form)"

  moderation_edit_page = http.get("#{post_path}/edit", 'Cookie' => cookie)
  moderation_index = nil
  moderation_edit_page.body.scan(/name="post\[comments_attributes\]\[(\d+)\]\[id\]"[^>]*value="(\d+)"/) do |index, id|
    moderation_index = index if id.to_i != comment_id.to_i
  end
  raise 'edit form should render a nested field for the comment to be moderated' unless moderation_index
  raise 'moderation nested field should carry the unmoderated body' unless moderation_edit_page.body.include?('unmoderated text')
  puts "GET #{post_path}/edit -> FormBuilder#fields_for rendered comments_attributes[#{moderation_index}] for the new comment"

  moderation_lock_version = moderation_edit_page.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  moderate_body_edit = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (tab A won)', 'post[body]' => 'Saved first.',
    'post[lock_version]' => moderation_lock_version,
    "post[comments_attributes][#{moderation_index}][id]" => moderation_edit_page.body[/name="post\[comments_attributes\]\[#{moderation_index}\]\[id\]"[^>]*value="(\d+)"/, 1],
    "post[comments_attributes][#{moderation_index}][body]" => 'Edited by the post author, not the commenter',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  moderate_edit = http.post(post_path, moderate_body_edit, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the moderation edit to redirect, got #{moderate_edit.code}" unless moderate_edit.code == '302'
  moderate_edit_cookie = cookie_from(moderate_edit)
  cookie = moderate_edit_cookie unless moderate_edit_cookie.empty?
  puts "POST #{post_path} with comments_attributes[#{moderation_index}][body] -> #{moderate_edit.code}"

  moderated_show = http.get(post_path, 'Cookie' => cookie)
  unless moderated_show.body.include?('Edited by the post author, not the commenter')
    raise 'expected the comment moderated through the post edit form to show its new body on the post page'
  end
  raise 'the other comment must not have been touched by this moderation edit' unless moderated_show.body.include?('Nice post, tab A won!')
  puts "GET #{post_path} -> the moderated comment shows its new body, the untouched comment (tab A/B locking scene) is unaffected"

  moderation_edit_page_2 = http.get("#{post_path}/edit", 'Cookie' => cookie)
  moderation_lock_version_2 = moderation_edit_page_2.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  destroy_via_moderation_body = URI.encode_www_form(
    'post[title]' => 'Hello from Prism (tab A won)', 'post[body]' => 'Saved first.',
    'post[lock_version]' => moderation_lock_version_2,
    "post[comments_attributes][#{moderation_index}][id]" => moderation_edit_page.body[/name="post\[comments_attributes\]\[#{moderation_index}\]\[id\]"[^>]*value="(\d+)"/, 1],
    "post[comments_attributes][#{moderation_index}][_destroy]" => '1',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  destroy_via_moderation = http.post(post_path, destroy_via_moderation_body,
                                      'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the moderation destroy to redirect, got #{destroy_via_moderation.code}" unless destroy_via_moderation.code == '302'
  moderation_destroy_cookie = cookie_from(destroy_via_moderation)
  cookie = moderation_destroy_cookie unless moderation_destroy_cookie.empty?
  puts "POST #{post_path} with comments_attributes[#{moderation_index}][_destroy]=1 -> #{destroy_via_moderation.code} " \
       '(comment removed through accepts_nested_attributes_for, not its own /comments/:id route)'

  after_moderation_destroy = http.get('/', 'Cookie' => cookie)
  unless after_moderation_destroy.body.include?('1 comment(s)')
    raise 'expected comments_count to drop back to 1 - counter_cache after_destroy still fires when a comment ' \
          'is destroyed through nested attributes, not just through CommentsController#destroy'
  end
  puts "GET / -> post listing shows '1 comment(s)' again (counter_cache after_destroy ran for the nested-attributes destroy too)"

  puts '-' * 40
  puts 'CommentsController#index - comments now get their own paginated URL, not just whatever fits ' \
       'inline on posts#show'
  11.times do |i|
    filler_comment_body = URI.encode_www_form(
      'comment[author]' => 'Pager', 'comment[body]' => "Filler comment #{i + 1}", 'authenticity_token' => token
    )
    filler_comment = http.post("/posts/#{post_id}/comments", filler_comment_body,
                                'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected filler comment #{i + 1} to redirect, got #{filler_comment.code}" unless filler_comment.code == '302'
  end
  puts 'created 11 filler comments (12 total: the surviving tab-A comment plus these) to exercise ' \
       'Orm::Pagination on comments#index'

  comments_page_one = http.get("/posts/#{post_id}/comments", 'Cookie' => cookie)
  comments_page_two = http.get("/posts/#{post_id}/comments?page=2", 'Cookie' => cookie)
  puts "GET /posts/#{post_id}/comments -> #{comments_page_one.code}, GET ...?page=2 -> #{comments_page_two.code}"
  raise 'comments page 1 should render pagination nav links' unless comments_page_one.body.include?('class="pagination"')
  unless comments_page_one.body.scan('class="comment"').size == 10
    raise 'comments page 1 should show exactly 10 comments (Orm::Pagination default per-page)'
  end
  raise 'comments page 2 should show the remaining 2 comments' unless comments_page_two.body.scan('class="comment"').size == 2

  comments_etag = comments_page_one['etag']
  raise 'comments#index should set an ETag now that it uses fresh_when' unless comments_etag
  puts "GET /posts/#{post_id}/comments -> ETag=#{comments_etag}"

  conditional_comments = http.get("/posts/#{post_id}/comments", 'Cookie' => cookie, 'If-None-Match' => comments_etag)
  puts "GET /posts/#{post_id}/comments with If-None-Match: #{comments_etag} -> #{conditional_comments.code}"
  unless conditional_comments.code == '304'
    raise "expected a fresh conditional GET on comments#index to return 304, got #{conditional_comments.code}"
  end
  raise '304 response on comments#index must not carry a body' unless conditional_comments.body.to_s.empty?

  one_more_comment_body = URI.encode_www_form(
    'comment[author]' => 'Pager', 'comment[body]' => 'One more filler comment', 'authenticity_token' => token
  )
  one_more_comment = http.post("/posts/#{post_id}/comments", one_more_comment_body,
                                'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the extra filler comment to redirect, got #{one_more_comment.code}" unless one_more_comment.code == '302'

  now_stale_comments = http.get("/posts/#{post_id}/comments", 'Cookie' => cookie, 'If-None-Match' => comments_etag)
  puts "GET /posts/#{post_id}/comments with the OLD If-None-Match after a new comment -> #{now_stale_comments.code}"
  unless now_stale_comments.code == '200'
    raise "expected the stale conditional GET on comments#index to return 200, got #{now_stale_comments.code}"
  end
  raise 'the fresh comments#index render must carry a NEW ETag, not the stale one' if now_stale_comments['etag'] == comments_etag

  comments_json = http.get("/posts/#{post_id}/comments.json", 'Cookie' => cookie)
  parsed_comments_json = JSON.parse(comments_json.body)
  puts "GET /posts/#{post_id}/comments.json -> #{comments_json.code} (#{parsed_comments_json.size} comments on this page)"
  raise 'comments#index.json should return only the current page (10), not every comment' unless parsed_comments_json.size == 10
  unless parsed_comments_json.first.keys.sort == %w[author body id post_id status]
    raise 'comments#index.json entries should carry exactly id/author/body/post_id/status'
  end

  post_show_with_comments_link = http.get(post_path, 'Cookie' => cookie)
  unless post_show_with_comments_link.body.include?("/posts/#{post_id}/comments")
    raise 'post show page should link to the new paginated comments#index'
  end
  puts "GET #{post_path} -> links to the new /posts/#{post_id}/comments page"

  rejected = http.post('/posts', URI.encode_www_form('post[title]' => 'no token'),
                        'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST /posts without a CSRF token -> #{rejected.code} (expected 422)"
  raise 'missing CSRF token should have been rejected' unless rejected.code == '422'

  5.times do |i|
    filler_body = URI.encode_www_form(
      'post[title]' => "Filler post #{i + 1}", 'post[body]' => 'Padding content to exercise pagination.',
      'authenticity_token' => token
    )
    filler = http.post('/posts', filler_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
    raise "expected filler post #{i + 1} to redirect, got #{filler.code}" unless filler.code == '302'
  end
  puts 'created 5 filler posts (6 total) to exercise Orm::Pagination on posts#index'

  page_one = http.get('/posts', 'Cookie' => cookie)
  page_two = http.get('/posts?page=2', 'Cookie' => cookie)
  puts "GET /posts -> #{page_one.code}, GET /posts?page=2 -> #{page_two.code}"
  raise 'page 1 should render pagination nav links' unless page_one.body.include?('class="pagination"')
  raise 'page 2 should render a different set of posts than page 1' if page_one.body == page_two.body
  raise 'page 2 should still contain the oldest post (Hello from Prism)' unless page_two.body.include?('Hello from Prism')

  fresh_index = http.get('/posts', 'Cookie' => cookie)
  index_etag = fresh_index['etag']
  raise 'posts#index should set an ETag now that it uses fresh_when' unless index_etag
  puts "GET /posts -> #{fresh_index.code}, ETag=#{index_etag}"

  conditional_index = http.get('/posts', 'Cookie' => cookie, 'If-None-Match' => index_etag)
  puts "GET /posts with If-None-Match: #{index_etag} -> #{conditional_index.code}"
  raise "expected a fresh conditional GET on the index to return 304, got #{conditional_index.code}" unless conditional_index.code == '304'
  raise '304 response on the index must not carry a body' unless conditional_index.body.to_s.empty?

  another_filler_body = URI.encode_www_form(
    'post[title]' => 'One more filler post', 'post[body]' => 'Exercises index etag invalidation.',
    'authenticity_token' => token
  )
  another_filler = http.post('/posts', another_filler_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the extra filler post to redirect, got #{another_filler.code}" unless another_filler.code == '302'
  index_after_new_post_cookie = cookie_from(another_filler)
  cookie = index_after_new_post_cookie unless index_after_new_post_cookie.empty?

  now_stale_index = http.get('/posts', 'Cookie' => cookie, 'If-None-Match' => index_etag)
  puts "GET /posts with the OLD If-None-Match after a new post -> #{now_stale_index.code}"
  unless now_stale_index.code == '200'
    raise "expected the stale index ETag to be rejected after a new post shifted pagination, got #{now_stale_index.code}"
  end
  raise 'the fresh index render must carry a NEW ETag, not the stale one' if now_stale_index['etag'] == index_etag
  puts "GET /posts -> #{now_stale_index.code} (ETag changed after a new post shifted total_count/pagination)"

  puts '-' * 40
  puts "exercising Post's enum :status (draft/published/archived) via #publish/#unpublish"
  status_target_path = another_filler['location']

  before_unpublish_index = http.get('/posts', 'Cookie' => cookie)
  raise "'One more filler post' should be visible on the index" unless before_unpublish_index.body.include?('One more filler post')

  unpublish_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  unpublish = http.post("#{status_target_path}/unpublish", unpublish_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{status_target_path}/unpublish with _method=PATCH -> #{unpublish.code} Location=#{unpublish['location']}"
  raise "expected the unpublish action to redirect, got #{unpublish.code}" unless unpublish.code == '302'
  unpublish_cookie = cookie_from(unpublish)
  cookie = unpublish_cookie unless unpublish_cookie.empty?

  after_unpublish_index = http.get('/posts', 'Cookie' => cookie)
  raise 'a draft post must not appear on the public index' if after_unpublish_index.body.include?('One more filler post')

  draft_show = http.get(status_target_path, 'Cookie' => cookie)
  raise "a draft's own show page must still be reachable directly by its author" unless draft_show.code == '200'
  raise 'show page should render the Draft status label while unpublished' unless draft_show.body.include?('Draft')
  puts "GET #{status_target_path} while a draft -> #{draft_show.code} (still reachable directly, index no longer lists it)"

  republish_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  republish = http.post("#{status_target_path}/publish", republish_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{status_target_path}/publish with _method=PATCH -> #{republish.code}"
  raise "expected the publish action to redirect, got #{republish.code}" unless republish.code == '302'
  republish_cookie = cookie_from(republish)
  cookie = republish_cookie unless republish_cookie.empty?

  after_republish_index = http.get('/posts', 'Cookie' => cookie)
  raise 're-published post should be back on the public index' unless after_republish_index.body.include?('One more filler post')
  puts 'GET /posts -> re-published post is listed again'

  puts '-' * 40
  puts "checking that add_index :posts, :status (db/migrate/#{'20260907000003_add_index_on_posts_status.rb'}) is really used by the live posts#index request, not just the synthetic CountingIndexStore in test/test_orm_index.rb"
  index_usage_log_offset = File.size(log_path)
  http.get('/posts', 'Cookie' => cookie)
  index_usage_log_lines = File.read(log_path)[index_usage_log_offset..].to_s
  unless index_usage_log_lines.include?('operation="SELECT INDEX"') && index_usage_log_lines.include?('table="posts"')
    raise 'expected Post.published (the enum scope backing posts#index, -> where(status: 1)) to hit the new posts.status index instead of a full table scan'
  end
  raise 'expected the posts.status index lookup to be reported as covering the status column' unless index_usage_log_lines.include?('columns=["status"]')
  puts '  sql.prism log line for this GET /posts shows operation="SELECT INDEX" table="posts" columns=["status"] - the enum scope reused the real index, zero full scan'

  puts '-' * 40
  puts "checking the posts#index ?days= recency filter (Post.created_within, db/migrate/20260907000004_add_index_on_posts_created_at.rb)"
  recency_log_offset = File.size(log_path)
  recent_index = http.get('/posts?days=7', 'Cookie' => cookie)
  raise "expected GET /posts?days=7 to succeed, got #{recent_index.code}" unless recent_index.code == '200'
  raise 'every post in this demo run was just created, so the 7-day filter must still show them' unless recent_index.body.include?('One more filler post')
  recency_log_lines = File.read(log_path)[recency_log_offset..].to_s
  # .published is chained BEFORE .created_within on posts#index, and
  # Relation#indexed_candidates tries an equality-covering index before it
  # ever looks at ranges - so this combined query resolves entirely through
  # the posts.status index (see the "SELECT INDEX" check above) and never
  # reaches the created_at range index at all. That is correct (still zero
  # full scans), just not proof of the range index specifically - see the
  # direct Post.created_within call below for that.
  if recency_log_lines.include?("operation=\"SELECT\" table=\"posts\"")
    raise 'expected Post.published.created_within(...) (posts#index ?days= filter) to resolve through an index, not a bare full table scan'
  end
  puts '  GET /posts?days=7 resolved through an index (posts.status, since .published already narrows it down), zero full scan'

  ancient_index = http.get('/posts?days=0', 'Cookie' => cookie)
  raise "expected GET /posts?days=0 (filter off) to succeed, got #{ancient_index.code}" unless ancient_index.code == '200'
  raise 'days=0 must mean "no recency filter", same post set as plain /posts' unless ancient_index.body.include?('One more filler post')
  puts '  GET /posts?days=0 -> filter off, same post set as an unfiltered /posts'

  # Isolates Post.created_within itself (no .published in front of it, so
  # nothing else could resolve the query first) to prove the created_at
  # range index specifically is what's backing it, not just an accident of
  # chaining order.
  range_only_log_offset = File.size(log_path)
  recent_unscoped = Post.created_within(7).to_a
  raise 'Post.created_within(7) should include every post created during this demo run' if recent_unscoped.empty?
  range_only_log_lines = File.read(log_path)[range_only_log_offset..].to_s
  unless range_only_log_lines.include?('operation="SELECT INDEX RANGE"') && range_only_log_lines.include?('table="posts"')
    raise 'expected the standalone Post.created_within(7) to hit the posts.created_at range index instead of a full table scan'
  end
  raise 'expected the posts.created_at range index lookup to be reported as covering the created_at column' unless range_only_log_lines.include?('columns=["created_at"]')
  puts '  Post.created_within(7) alone -> sql.prism shows operation="SELECT INDEX RANGE" table="posts" columns=["created_at"], zero full scan'

  puts '-' * 40
  puts 'checking GET /posts/export (PostsController#export) - Prism::Controller#stream over a REAL socket, not just a directly-invoked App#call(env) tuple like test_controller_streaming.rb/test_server.rb already cover'
  export_response = http.get('/posts/export', 'Cookie' => cookie)
  raise "expected GET /posts/export to succeed, got #{export_response.code}" unless export_response.code == '200'
  raise 'expected the export to be sent as chunked Transfer-Encoding, not a single buffered Content-Length body' unless export_response['transfer-encoding'] == 'chunked'
  raise 'a chunked response must not also carry a Content-Length' if export_response['content-length']
  raise "expected text/csv, got #{export_response['content-type']}" unless export_response['content-type'] == 'text/csv'
  csv_lines = export_response.body.lines
  raise 'expected a header row followed by one row per published post' unless csv_lines.first == "id,title,created_at\n"
  raise 'expected the re-published post from the enum scene above to be in the export' unless export_response.body.include?('One more filler post')
  expected_row_count = Post.published.count
  raise "expected #{expected_row_count} data row(s) (Post.published.count), got #{csv_lines.size - 1} - the export scope must exclude drafts/archived just like .published does" unless csv_lines.size - 1 == expected_row_count
  puts "  GET /posts/export -> #{export_response.code}, Transfer-Encoding: chunked, #{expected_row_count} published post row(s) (matches Post.published.count exactly)"

  puts '-' * 40
  puts 'checking Prism::Middleware::Compression over a REAL socket - setting our own Accept-Encoding disables ' \
       "Net::HTTP's transparent auto-decoding, so response.body below is the raw wire bytes, not something " \
       'this script infers from matching decompressed content (which every other Net::HTTP call above already ' \
       'does silently, since Net::HTTP sends its own Accept-Encoding: gzip by default and decodes for us)'
  gzip_headers = {'Cookie' => cookie, 'Accept-Encoding' => 'gzip'}

  compressed_index = http.get('/posts', gzip_headers)
  raise "expected GET /posts to succeed, got #{compressed_index.code}" unless compressed_index.code == '200'
  raise 'expected Content-Encoding: gzip on a compressible HTML response' unless compressed_index['content-encoding'] == 'gzip'
  decompressed_index = Zlib::GzipReader.new(StringIO.new(compressed_index.body)).read
  raise 'expected the decompressed body to still be the same posts#index HTML' unless decompressed_index.include?('One more filler post')
  raise 'expected gzip to actually shrink a repetitive HTML page' unless compressed_index.body.bytesize < decompressed_index.bytesize
  raise 'a compressed response Content-Length must describe the compressed bytes on the wire, not the original size' \
    unless compressed_index['content-length'].to_i == compressed_index.body.bytesize
  puts "  GET /posts (Accept-Encoding: gzip) -> #{compressed_index.code}, Content-Encoding: gzip, " \
       "#{decompressed_index.bytesize} bytes -> #{compressed_index.body.bytesize} bytes on the wire"

  compressed_export = http.get('/posts/export', gzip_headers)
  raise "expected GET /posts/export to succeed, got #{compressed_export.code}" unless compressed_export.code == '200'
end

server.stop
puts '-' * 40
puts 'blog demo done (process about to exit; data stays on disk for the restart check)'
