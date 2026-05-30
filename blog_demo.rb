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
end

server.stop
puts '-' * 40
puts 'blog demo done (process about to exit; data stays on disk for the restart check)'
