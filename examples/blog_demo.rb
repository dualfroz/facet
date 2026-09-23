$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'facet'
require 'net/http'
require 'zlib'
require 'stringio'
require 'csv'
require_relative 'blog/app'

server = Facet::Server.new(Blog, port: 0).start
port = server.port
puts "blog demo server on port #{port}"
puts "database file: #{File.join(__dir__, 'blog/db/development.pstore')}"
log_path = File.join(__dir__, 'blog/log/development.log')
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
  manifest = JSON.parse(File.read(File.join(__dir__, 'blog/public/assets/manifest.json')))
  unless css_response.code == '200' && css_response['cache-control'] == 'public, max-age=31536000, immutable'
    raise "expected the fingerprinted stylesheet to be served with a far-future Cache-Control, got #{css_response.code} #{css_response['cache-control'].inspect}"
  end
  unless manifest['stylesheets/application.css'] == css_href.delete_prefix('/assets/')
    raise 'expected the on-disk manifest.json to agree with the href the layout rendered'
  end
  puts "GET #{css_href} -> #{css_response.code}, Cache-Control=#{css_response['cache-control']}"
  puts "GET #{js_src} -> #{js_response.code} (Facet::Assets::Compiler fingerprinted both files, manifest.json on disk matches)"

  puts '-' * 40
  puts 'Conditional GET (Facet::StaticCache, RFC 7232/7233) against the fingerprinted stylesheet, over the ' \
       'real Facet::Server socket - Middleware::Assets hands out a STRONG ETag here (derived from the ' \
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

  writer_user = User.find_by(email: 'writer@example.com')
  raise 'expected to find the newly signed-up user back by plaintext email (deterministic encryption)' unless writer_user
  writer_raw_row = Facet::Orm.store.find(:users, writer_user.id)
  if writer_raw_row['email'] == 'writer@example.com' || !writer_raw_row['email'].to_s.include?('--')
    raise "expected users.email to be stored encrypted at rest, got #{writer_raw_row['email'].inspect}"
  end
  puts "  users.email stored encrypted at rest (#{writer_raw_row['email'][0, 20]}...), decrypts back to #{writer_user.email}"

  boundary = '----FacetBlogDemoBoundary'
  body = multipart_body(
    boundary,
    fields: { 'post[title]' => 'Hello from Facet', 'post[body]' => 'This record was written through the ORM-lite file store.',
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
  post_create_cookie = cookie_from(create)
  cookie = post_create_cookie unless post_create_cookie.empty?

  show = http.get(post_path, 'Cookie' => cookie)
  puts "GET #{post_path} -> #{show.code}"
  raise 'cover filename missing from show page' unless show.body.include?('/uploads/')
  post_id = post_path.split('/').last
  post_row_id = Post.find_by!(slug: post_id).id
  cover_path = show.body[%r{/uploads/([^"']+)}, 0]
  cover_file = File.join(__dir__, 'blog/public', cover_path)
  raise "uploaded cover file missing on disk: #{cover_file}" unless File.exist?(cover_file)

  puts '-' * 40
  puts 'HTTP Range requests against the uploaded cover (Facet::HttpRange, RFC 7233), served by ' \
       'Middleware::Static over the real Facet::Server socket - not just .call(env) in a unit test'
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
       '(the asymmetry Facet::StaticCache exists to get right)'

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
  puts "GET #{post_path} -> tab A's comment body survives untouched, Facet::Orm::Locking prevented the lost update"

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
  puts "GET #{post_path} -> #{now_stale.code} (ETag changed after a comment was added, Facet::ConditionalGet is content-aware)"

  json_index = http.get('/posts.json')
  puts "GET /posts.json -> #{json_index.code} #{json_index['content-type']}"
  parsed = JSON.parse(json_index.body)
  raise 'json index did not include the new post' unless parsed.any? { |row| row['title'] == 'Hello from Facet' }

  puts '-' * 40
  puts 'CORS: Facet::Middleware::Cors + Facet::Cors, matched against the .json API surface only - a ' \
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

  admin_origin = 'https://admin.blog.example.com'
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
  puts 'JSON:API-lite validation/conflict errors (Facet::Orm::Errors#to_jsonapi + ' \
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
  raise 'edit form should be pre-filled with the current title' unless edit_page.body.include?('value="Hello from Facet"')

  puts '-' * 40
  puts 'PostsController#preview - diffs a proposed edit against the saved row without persisting it, ' \
       'using Facet::Orm::Dirty#restore_attributes to revert its Post instance so the SAME response can ' \
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
  unless preview.body.include?('Hello from Facet')
    raise "preview response should still show the post's actual saved title - " \
          "Post#restore_attributes should have reverted the in-memory change before rendering"
  end
  puts "POST #{post_path}/preview -> #{preview.code}, response shows both the proposed title (diff) and the " \
       "still-saved current title (restore_attributes reverted the model instance within the same request)"

  not_yet_saved = http.get(post_path, 'Cookie' => cookie)
  raise 'the previewed title must never have been persisted' if not_yet_saved.body.include?('Previewed title, not yet saved')
  puts "GET #{post_path} -> the previewed title was never written to disk, only diffed"

  update_body = URI.encode_www_form(
    'post[title]' => 'Hello from Facet (edited)', 'post[body]' => 'Updated through a dirty-tracked update.',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  update = http.post(post_path, update_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{post_path} with _method=PATCH -> #{update.code} Location=#{update['location']}"
  raise "expected the update to redirect back to the post, got #{update.code}" unless update.code == '302'
  post_update_cookie = cookie_from(update)
  cookie = post_update_cookie unless post_update_cookie.empty?

  updated_show = http.get(post_path, 'Cookie' => cookie)
  raise 'updated title did not appear on the show page' unless updated_show.body.include?('Hello from Facet (edited)')
  unless updated_show.body.include?('changed: title, body') || updated_show.body.include?('zmienione: title, body')
    raise 'Facet::Orm::Dirty-backed notice should list the fields that actually changed'
  end
  puts "GET #{post_path} -> title/body updated, dirty-tracking notice named the changed fields"

  noop_body = URI.encode_www_form(
    'post[title]' => 'Hello from Facet (edited)', 'post[body]' => 'Updated through a dirty-tracked update.',
    '_method' => 'PATCH', 'authenticity_token' => token
  )
  noop = http.post(post_path, noop_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the no-op update to redirect too, got #{noop.code}" unless noop.code == '302'
  noop_cookie = cookie_from(noop)
  cookie = noop_cookie unless noop_cookie.empty?
  noop_show = http.get(post_path, 'Cookie' => cookie)
  unless noop_show.body.include?('Nothing changed') || noop_show.body.include?('Nic sie nie zmienilo')
    raise 'submitting identical values should report that Facet::Orm::Dirty saw zero real changes'
  end
  puts "POST #{post_path} with identical values -> Post#saved_changes was empty, notice said nothing changed"

  tab_a_edit = http.get("#{post_path}/edit", 'Cookie' => cookie)
  tab_b_edit = http.get("#{post_path}/edit", 'Cookie' => cookie)
  tab_a_lock_version = tab_a_edit.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  tab_b_lock_version = tab_b_edit.body[/name="post\[lock_version\]"[^>]*value="([^"]*)"/, 1]
  raise 'edit form should carry the current lock_version in a hidden field' if tab_a_lock_version.to_s.empty?
  raise 'both tabs should have observed the same lock_version before either saved' unless tab_a_lock_version == tab_b_lock_version

  tab_a_save_body = URI.encode_www_form(
    'post[title]' => 'Hello from Facet (tab A won)', 'post[body]' => 'Saved first.',
    'post[lock_version]' => tab_a_lock_version, '_method' => 'PATCH', 'authenticity_token' => token
  )
  tab_a_save = http.post(post_path, tab_a_save_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected tab A's save to succeed, got #{tab_a_save.code}" unless tab_a_save.code == '302'
  tab_a_cookie = cookie_from(tab_a_save)
  cookie = tab_a_cookie unless tab_a_cookie.empty?
  puts "POST #{post_path}/edit tab A (lock_version=#{tab_a_lock_version}) -> #{tab_a_save.code}, saved first"

  tab_b_save_body = URI.encode_www_form(
    'post[title]' => 'Hello from Facet (tab B lost)', 'post[body]' => 'Submitted stale, should be rejected.',
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
  raise "tab B's rejected write must not have overwritten tab A's title" unless after_conflict.body.include?('Hello from Facet (tab A won)')
  raise "tab B's rejected write must not have leaked through" if after_conflict.body.include?('tab B lost')
  puts "GET #{post_path} -> tab A's title survives untouched, Facet::Orm::Locking prevented the lost update"

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
    'post[title]' => 'Hello from Facet (tab A won)', 'post[body]' => 'Saved first.',
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
    'post[title]' => 'Hello from Facet (tab A won)', 'post[body]' => 'Saved first.',
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
  raise 'page 2 should still contain the oldest post (Hello from Facet)' unless page_two.body.include?('Hello from Facet')

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
  puts '  sql.facet log line for this GET /posts shows operation="SELECT INDEX" table="posts" columns=["status"] - the enum scope reused the real index, zero full scan'

  puts '-' * 40
  puts "checking the posts#index ?days= recency filter (Post.created_within, db/migrate/20260907000004_add_index_on_posts_created_at.rb)"
  recency_log_offset = File.size(log_path)
  recent_index = http.get('/posts?days=7', 'Cookie' => cookie)
  raise "expected GET /posts?days=7 to succeed, got #{recent_index.code}" unless recent_index.code == '200'
  raise 'every post in this demo run was just created, so the 7-day filter must still show them' unless recent_index.body.include?('One more filler post')
  recency_log_lines = File.read(log_path)[recency_log_offset..].to_s
  if recency_log_lines.include?("operation=\"SELECT\" table=\"posts\"")
    raise 'expected Post.published.created_within(...) (posts#index ?days= filter) to resolve through an index, not a bare full table scan'
  end
  puts '  GET /posts?days=7 resolved through an index (posts.status, since .published already narrows it down), zero full scan'

  ancient_index = http.get('/posts?days=0', 'Cookie' => cookie)
  raise "expected GET /posts?days=0 (filter off) to succeed, got #{ancient_index.code}" unless ancient_index.code == '200'
  raise 'days=0 must mean "no recency filter", same post set as plain /posts' unless ancient_index.body.include?('One more filler post')
  puts '  GET /posts?days=0 -> filter off, same post set as an unfiltered /posts'

  range_only_log_offset = File.size(log_path)
  recent_unscoped = Post.created_within(7).to_a
  raise 'Post.created_within(7) should include every post created during this demo run' if recent_unscoped.empty?
  range_only_log_lines = File.read(log_path)[range_only_log_offset..].to_s
  unless range_only_log_lines.include?('operation="SELECT INDEX RANGE"') && range_only_log_lines.include?('table="posts"')
    raise 'expected the standalone Post.created_within(7) to hit the posts.created_at range index instead of a full table scan'
  end
  raise 'expected the posts.created_at range index lookup to be reported as covering the created_at column' unless range_only_log_lines.include?('columns=["created_at"]')
  puts '  Post.created_within(7) alone -> sql.facet shows operation="SELECT INDEX RANGE" table="posts" columns=["created_at"], zero full scan'

  puts '-' * 40
  puts 'checking GET /posts/export (PostsController#export) - Facet::Controller#stream over a REAL socket, not just a directly-invoked App#call(env) tuple like test_controller_streaming.rb/test_server.rb already cover'
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
  puts 'checking Facet::Middleware::Compression over a REAL socket - setting our own Accept-Encoding disables ' \
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
  raise 'expected chunked Transfer-Encoding and gzip Content-Encoding to compose on the streamed export' \
    unless compressed_export['transfer-encoding'] == 'chunked' && compressed_export['content-encoding'] == 'gzip'
  raise 'a chunked response must still never carry a Content-Length, gzipped or not' if compressed_export['content-length']
  decompressed_export = Zlib::GzipReader.new(StringIO.new(compressed_export.body)).read
  raise 'gzipping a StreamingBody chunk-by-chunk must reproduce byte-for-byte the same CSV as the uncompressed export' \
    unless decompressed_export == export_response.body
  puts '  GET /posts/export (Accept-Encoding: gzip) -> chunked + gzip together, decompresses to the exact same CSV'

  small_json_probe = http.get('/assets/manifest.json', gzip_headers)
  raise "expected GET /assets/manifest.json to succeed, got #{small_json_probe.code}" unless small_json_probe.code == '200'
  raise 'expected a tiny response body to be left alone (below the compression threshold)' if small_json_probe['content-encoding']
  puts "  GET /assets/manifest.json (Accept-Encoding: gzip) -> #{small_json_probe.code}, no Content-Encoding " \
       "(#{small_json_probe.body.bytesize} bytes, below the size threshold)"

  puts '-' * 40
  puts 'draining the background job queue (NotificationMailer.deliver_later from the post#create above)'
  worker = Facet::Jobs::Worker.new(Facet::Jobs.default_queue)
  processed = worker.work_off
  puts "worker processed #{processed} job(s); Facet::Mailer.deliveries=#{Facet::Mailer.deliveries.size}"
  raise 'expected the new-post notification email to have been delivered' if Facet::Mailer.deliveries.empty?
  puts "last delivery subject: #{Facet::Mailer.deliveries.last.subject}"

  preview_index = http.get('/rails/mailers')
  puts "GET /rails/mailers -> #{preview_index.code}"
  raise 'mailer preview index did not list notification_mailer' unless preview_index.body.include?('notification_mailer')

  preview_email = http.get('/rails/mailers/notification_mailer/new_post')
  puts "GET /rails/mailers/notification_mailer/new_post -> #{preview_email.code}"
  unless preview_email.body.include?('New post:')
    raise 'mailer preview did not render the new_post email subject'
  end

  puts '-' * 40
  puts 'checking POST /posts/import (Post.import_csv) - the CSV counterpart of GET /posts/export above, and the ' \
       "only place in this app where Post.create_with_unique_slug's per-row transaction(requires_new: true) " \
       'savepoint actually matters (import_csv wraps the whole batch in one outer Post.transaction, so a plain ' \
       'nested transaction per row would either roll back rows already imported earlier in the same batch, or ' \
       'leave a doomed row enlisted to wrongly fire its after_commit notification once the batch commits)'
  import_csv_body = CSV.generate do |csv|
    csv << %w[title body]
    csv << ['Bulk Import Special Report', 'First half of a two-part report.']
    csv << ['Bulk Import Special Report',
            'Second half, same title on purpose - this row must collide on the ' \
            'first-choice slug (a REAL Store::UniqueConstraintViolation from the unique index on posts.slug, ' \
            'not a mocked one) and retry with a numeric suffix.']
    csv << ['', 'This row has no title and must be skipped without aborting the rows around it.']
    csv << ['Another Imported Post', 'A normal row after the skipped one, proving the batch keeps going.']
  end
  posts_before_import = Post.count
  deliveries_before_import = Facet::Mailer.deliveries.size

  import_boundary = '----FacetBlogDemoImportBoundary'
  import_body = multipart_body(
    import_boundary,
    fields: { 'authenticity_token' => token },
    files: { 'file' => ['posts.csv', 'text/csv', import_csv_body] }
  )
  import_response = http.post(
    '/posts/import', import_body,
    'Content-Type' => "multipart/form-data; boundary=#{import_boundary}", 'Cookie' => cookie
  )
  puts "POST /posts/import (multipart CSV: 2 unique rows + 1 duplicate-titled row + 1 blank-titled row) -> " \
       "#{import_response.code} Location=#{import_response['location']}"
  raise "expected the import to redirect back to /posts, got #{import_response.code}" unless import_response.code == '302'
  import_cookie = cookie_from(import_response)
  cookie = import_cookie unless import_cookie.empty?

  imported_count = Post.count - posts_before_import
  raise "expected exactly 3 new posts (2 unique-titled rows + 1 retried duplicate), got #{imported_count}" unless imported_count == 3

  special_report = Post.where(title: 'Bulk Import Special Report').order(:id, :asc).to_a
  raise 'expected both duplicate-titled rows to have been imported' unless special_report.size == 2
  unless special_report.first.slug == 'bulk-import-special-report'
    raise "expected the first row's slug to be the plain, unsuffixed base, got #{special_report.first.slug.inspect}"
  end
  unless special_report.last.slug == 'bulk-import-special-report-2'
    raise "expected the second row's real unique-index collision to have been retried with a numeric suffix, " \
          "got #{special_report.last.slug.inspect}"
  end
  puts "  both duplicate-titled rows imported: slugs #{special_report.map(&:slug).inspect} " \
       '(a real Store::UniqueConstraintViolation retried via transaction(requires_new: true), not a mocked collision)'

  another = Post.find_by(title: 'Another Imported Post')
  raise 'expected the row after the skipped blank-titled one to have been imported too' unless another
  puts "  row after the skipped blank-titled row was still imported (slug=#{another.slug.inspect}) - " \
       "Post.import_csv's outer transaction survived the skip instead of losing the whole batch"

  import_worker = Facet::Jobs::Worker.new(Facet::Jobs.default_queue)
  import_processed = import_worker.work_off
  new_deliveries = Facet::Mailer.deliveries.size - deliveries_before_import
  puts "worker processed #{import_processed} job(s) from the import; #{new_deliveries} new notification email(s)"
  unless new_deliveries == 3
    raise "expected exactly 3 new notification emails (one per actually-imported post, none for the skipped " \
          "blank-titled row or for either retry attempt on the duplicate title), got #{new_deliveries}"
  end

  puts '-' * 40
  puts 'reserved-slug check: a post titled the same as a collection route (Post.reserved_slugs, derived ' \
       "from Blog.router itself) must not steal that route's URL - a plain title-derived slug 'trash' would " \
       'otherwise be permanently unreachable at its own /posts/trash show page, since Application.resources ' \
       'registers the literal GET /posts/trash collection route before the generic GET /posts/:slug show route ' \
       'it would shadow'
  raise 'Post.reserved_slugs should include both collection routes registered under /posts' \
    unless (%w[trash export] - Post.reserved_slugs).empty?

  reserved_title_body = URI.encode_www_form(
    'post[title]' => 'Trash', 'post[body]' => 'This title collides with the /posts/trash collection route.',
    'authenticity_token' => token
  )
  reserved_title_create = http.post('/posts', reserved_title_body,
                                     'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  reserved_post_path = reserved_title_create['location']
  puts "POST /posts (title 'Trash') -> #{reserved_title_create.code} Location=#{reserved_post_path}"
  raise "expected a redirect to the new post, got #{reserved_title_create.code}" unless reserved_title_create.code == '302'
  reserved_post_cookie = cookie_from(reserved_title_create)
  cookie = reserved_post_cookie unless reserved_post_cookie.empty?

  reserved_slug = reserved_post_path.split('/').last
  raise "expected the base slug 'trash' to have been skipped in favor of a numeric suffix, got #{reserved_slug.inspect}" \
    if reserved_slug == 'trash'
  puts "  title 'Trash' -> slug #{reserved_slug.inspect} (base 'trash' skipped - it's a reserved collection route)"

  reserved_post_show = http.get(reserved_post_path, 'Cookie' => cookie)
  raise "expected GET #{reserved_post_path} to render the post's own show page" \
    unless reserved_post_show.code == '200' && reserved_post_show.body.include?('class="status"')
  puts "  GET #{reserved_post_path} -> #{reserved_post_show.code}, renders the post's own show page (not the trash listing)"

  trash_listing = http.get('/posts/trash', 'Cookie' => cookie)
  raise "expected GET /posts/trash to still resolve to the trash LISTING (not the post titled 'Trash')" \
    unless trash_listing.code == '200' && !trash_listing.body.include?('class="status"')
  puts "  GET /posts/trash -> #{trash_listing.code}, still the trash listing page, untouched by the reserved slug"

  puts '-' * 40
  puts 'featured flag check: Facet::Orm::Attributes/TypeCasting - the "featured" checkbox posts a String ' \
       '("1"/"0") like every HTML form field does, cast into a real TrueClass/FalseClass on write (Post#featured, ' \
       'see the model) so Post.featured (where(featured: true)) and the ?featured=1 index filter can actually ' \
       'match it - a raw uncast "1" string would never equal the Boolean true a plain `==` query compares against.'

  featured_body = URI.encode_www_form(
    'post[title]' => 'Featured launch announcement', 'post[body]' => 'This one should show up in the featured filter.',
    'post[featured]' => '1', 'authenticity_token' => token
  )
  featured_create = http.post('/posts', featured_body,
                               'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  featured_post_path = featured_create['location']
  puts "POST /posts (post[featured]=1) -> #{featured_create.code} Location=#{featured_post_path}"
  raise "expected a redirect to the new post, got #{featured_create.code}" unless featured_create.code == '302'
  featured_cookie = cookie_from(featured_create)
  cookie = featured_cookie unless featured_cookie.empty?

  featured_slug = featured_post_path.split('/').last
  featured_post = Post.find_by!(slug: featured_slug)
  unless featured_post.featured == true && featured_post.featured.is_a?(TrueClass)
    raise "expected Post#featured to be a real Boolean true, got #{featured_post.featured.inspect} (#{featured_post.featured.class})"
  end
  puts "  Post.find_by!(slug: #{featured_slug.inspect}).featured -> #{featured_post.featured.inspect} " \
       "(#{featured_post.featured.class}, not the raw \"1\" string the form submitted)"

  plain_body = URI.encode_www_form(
    'post[title]' => 'Ordinary, not featured', 'post[body]' => 'Should be absent from the featured filter.',
    'post[featured]' => '0', 'authenticity_token' => token
  )
  plain_create = http.post('/posts', plain_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected a redirect to the new post, got #{plain_create.code}" unless plain_create.code == '302'
  plain_cookie = cookie_from(plain_create)
  cookie = plain_cookie unless plain_cookie.empty?
  plain_slug = plain_create['location'].split('/').last

  featured_filter = http.get('/posts?featured=1', 'Cookie' => cookie)
  raise "expected GET /posts?featured=1 to succeed, got #{featured_filter.code}" unless featured_filter.code == '200'
  raise 'expected the featured post to appear in the ?featured=1 filter' \
    unless featured_filter.body.include?("id=\"post-#{featured_slug}\"")
  raise 'expected the non-featured post to be ABSENT from the ?featured=1 filter' \
    if featured_filter.body.include?("id=\"post-#{plain_slug}\"")
  raise 'expected the featured badge to render for the featured post' unless featured_filter.body.include?('featured-badge')
  puts "  GET /posts?featured=1 -> #{featured_filter.code}, includes the featured post, excludes the plain one " \
       '(Post.featured scope -> where(featured: true) matched a real Boolean, not a full-scan string comparison)'

  queried_featured = Post.where(featured: true).to_a
  raise "expected exactly the one featured post created above, got #{queried_featured.map(&:slug).inspect}" \
    unless queried_featured.map(&:slug) == [featured_slug]
  puts "  Post.where(featured: true) -> #{queried_featured.map(&:slug).inspect} (ORM query engine, not just the controller filter)"

  puts '-' * 40
  puts 'Post#acts_as_list (scoped by featured, see the model) - editors reorder the featured shelf with ' \
       '#move_up/#move_down (PostsController) instead of it always sorting by recency'
  second_featured_body = URI.encode_www_form(
    'post[title]' => 'Second featured pick', 'post[body]' => 'Also curated onto the shelf.',
    'post[featured]' => '1', 'authenticity_token' => token
  )
  second_featured_create = http.post('/posts', second_featured_body,
                                      'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected a redirect to the new post, got #{second_featured_create.code}" unless second_featured_create.code == '302'
  second_featured_cookie = cookie_from(second_featured_create)
  cookie = second_featured_cookie unless second_featured_cookie.empty?
  second_featured_slug = second_featured_create['location'].split('/').last

  third_featured_body = URI.encode_www_form(
    'post[title]' => 'Third featured pick', 'post[body]' => 'Bottom of the shelf for now.',
    'post[featured]' => '1', 'authenticity_token' => token
  )
  third_featured_create = http.post('/posts', third_featured_body,
                                     'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected a redirect to the new post, got #{third_featured_create.code}" unless third_featured_create.code == '302'
  third_featured_cookie = cookie_from(third_featured_create)
  cookie = third_featured_cookie unless third_featured_cookie.empty?
  third_featured_slug = third_featured_create['location'].split('/').last

  shelf_before = http.get('/posts?featured=1', 'Cookie' => cookie)
  order_before = [featured_slug, second_featured_slug, third_featured_slug].select { |slug| shelf_before.body.index("id=\"post-#{slug}\"") }
                                                                            .sort_by { |slug| shelf_before.body.index("id=\"post-#{slug}\"") }
  raise "expected the shelf in creation order, got #{order_before.inspect}" \
    unless order_before == [featured_slug, second_featured_slug, third_featured_slug]
  etag_before_reorder = shelf_before['etag']
  puts "  GET /posts?featured=1 -> shelf order #{order_before.inspect} (creation order, ETag #{etag_before_reorder})"

  move_down_log_offset = File.size(log_path)
  move_down_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  move_down = http.post("/posts/#{featured_slug}/move_down", move_down_body,
                         'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST /posts/#{featured_slug}/move_down with _method=PATCH -> #{move_down.code} Location=#{move_down['location']}"
  raise "expected the move_down action to redirect, got #{move_down.code}" unless move_down.code == '302'
  raise 'expected move_down to redirect back to the featured shelf' unless move_down['location'].end_with?('?featured=1')
  move_down_cookie = cookie_from(move_down)
  cookie = move_down_cookie unless move_down_cookie.empty?

  move_down_log_lines = File.read(log_path)[move_down_log_offset..].to_s
  unless move_down_log_lines.include?('operation="SELECT INDEX RANGE"') && move_down_log_lines.include?('table="posts"')
    raise 'expected Post#move_lower (scoped by featured) to hit the composite posts index instead of a full table scan'
  end
  unless move_down_log_lines.include?('columns=["featured", "position"]')
    raise 'expected the composite index lookup to be reported as covering featured and position together'
  end
  puts '  POST .../move_down -> sql.facet log shows operation="SELECT INDEX RANGE" table="posts" ' \
       'columns=["featured", "position"] - the scoped acts_as_list neighbor lookup used the composite index, zero full scan'

  stale_conditional = http.get('/posts?featured=1', 'Cookie' => cookie, 'If-None-Match' => etag_before_reorder)
  raise "expected the reorder to invalidate the old ETag (200, not 304), got #{stale_conditional.code}" \
    unless stale_conditional.code == '200'

  shelf_after = http.get('/posts?featured=1', 'Cookie' => cookie)
  order_after = [featured_slug, second_featured_slug, third_featured_slug].sort_by { |slug| shelf_after.body.index("id=\"post-#{slug}\"") }
  raise "expected #{featured_slug} to swap with #{second_featured_slug}, got #{order_after.inspect}" \
    unless order_after == [second_featured_slug, featured_slug, third_featured_slug]
  puts "  #{etag_before_reorder} rejected with a fresh 200 after the reorder, new shelf order #{order_after.inspect} " \
       "(#{featured_slug} swapped down with #{second_featured_slug}, #{third_featured_slug} untouched)"

  reordered_positions = Post.where(slug: [featured_slug, second_featured_slug, third_featured_slug]).to_a
                             .sort_by(&:position).map(&:slug)
  raise "expected the ORM's own position column to agree with the rendered order, got #{reordered_positions.inspect}" \
    unless reordered_positions == order_after
  puts "  Post.where(...).sort_by(&:position) -> #{reordered_positions.inspect} (ORM position column, not just markup order)"

  noop_move_up_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  noop_move_up = http.post("/posts/#{second_featured_slug}/move_up", noop_move_up_body,
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the move_up action to redirect, got #{noop_move_up.code}" unless noop_move_up.code == '302'
  noop_move_up_cookie = cookie_from(noop_move_up)
  cookie = noop_move_up_cookie unless noop_move_up_cookie.empty?
  shelf_still = http.get('/posts?featured=1', 'Cookie' => cookie)
  order_still = [featured_slug, second_featured_slug, third_featured_slug].sort_by { |slug| shelf_still.body.index("id=\"post-#{slug}\"") }
  raise "expected move_up on the shelf leader to be a no-op, got #{order_still.inspect}" unless order_still == order_after
  puts "  POST /posts/#{second_featured_slug}/move_up (already first) -> order unchanged, #{order_still.inspect}"

  puts '-' * 40
  puts "ownership check: a second user may not delete somebody else's post"
  other_signup_body = URI.encode_www_form(
    'user[email]' => 'reader2@example.com', 'user[password]' => 'another passphrase',
    'user[password_confirmation]' => 'another passphrase', 'authenticity_token' => token
  )
  other_signup = http.post('/users.json', other_signup_body,
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the JSON sign-up to return 201, got #{other_signup.code}" unless other_signup.code == '201'
  other_signup_json = JSON.parse(other_signup.body)
  raise 'JSON sign-up response should carry the new user id/email' unless other_signup_json['email'] == 'reader2@example.com' && other_signup_json['id']
  raise 'JSON sign-up response must never leak password_digest' if other_signup_json.key?('password_digest')
  puts "POST /users.json (sign up) -> #{other_signup.code}, id=#{other_signup_json['id']}, no password_digest in the body"
  fresh_cookie = cookie_from(other_signup)
  cookie = fresh_cookie unless fresh_cookie.empty?

  puts 'draining the background job queue again (User after_commit(on: :create) now also queues a welcome email ' \
       'AND a confirmation-instructions email - two separate after_commit(on: :create) hooks, see User)'
  deliveries_before_welcome = Facet::Mailer.deliveries.size
  processed_after_signup = worker.work_off
  puts "worker processed #{processed_after_signup} job(s); Facet::Mailer.deliveries=#{Facet::Mailer.deliveries.size}"
  raise 'expected new emails to have been delivered' unless Facet::Mailer.deliveries.size > deliveries_before_welcome
  new_deliveries_after_signup = Facet::Mailer.deliveries[deliveries_before_welcome..].select { |d| d.to == ['reader2@example.com'] }
  raise "expected exactly 2 emails to reader2 (welcome + confirmation instructions), got #{new_deliveries_after_signup.map(&:subject)}" \
    unless new_deliveries_after_signup.size == 2
  welcome_delivery = new_deliveries_after_signup.find { |d| d.subject.include?('Welcome') }
  confirmation_delivery = new_deliveries_after_signup.find { |d| d.subject.include?('Confirm your') }
  raise 'expected a welcome email among the 2 just delivered to reader2' unless welcome_delivery
  raise 'expected a confirmation-instructions email among the 2 just delivered to reader2' unless confirmation_delivery
  puts "delivery: to=#{welcome_delivery.to.first} subject=#{welcome_delivery.subject.inspect}"
  puts "delivery: to=#{confirmation_delivery.to.first} subject=#{confirmation_delivery.subject.inspect}"

  welcome_preview = http.get('/rails/mailers/notification_mailer/welcome')
  puts "GET /rails/mailers/notification_mailer/welcome -> #{welcome_preview.code}"
  raise 'welcome mailer preview did not render the welcome subject' unless welcome_preview.body.include?('Welcome to Facet Blog')

  forbidden_delete_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  forbidden_attempt = http.post(post_path, forbidden_delete_body,
                                 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{post_path} with _method=DELETE as a DIFFERENT user -> #{forbidden_attempt.code} " \
       "Location=#{forbidden_attempt['location']}"
  unless forbidden_attempt.code == '302' && forbidden_attempt['location'] == post_path
    raise "expected the second user's delete attempt to be redirected back to the post, got " \
          "#{forbidden_attempt.code} Location=#{forbidden_attempt['location']}"
  end

  forbidden_edit_page = http.get("#{post_path}/edit", 'Cookie' => cookie)
  puts "GET #{post_path}/edit as a DIFFERENT user -> #{forbidden_edit_page.code} Location=#{forbidden_edit_page['location']}"
  unless forbidden_edit_page.code == '302' && forbidden_edit_page['location'] == post_path
    raise "expected the second user's edit attempt to be redirected back to the post, got " \
          "#{forbidden_edit_page.code} Location=#{forbidden_edit_page['location']}"
  end

  forbidden_comment_edit = http.get("#{comment_edit_path}/edit", 'Cookie' => cookie)
  puts "GET #{comment_edit_path}/edit as a DIFFERENT user -> #{forbidden_comment_edit.code} " \
       "Location=#{forbidden_comment_edit['location']}"
  unless forbidden_comment_edit.code == '302' && forbidden_comment_edit['location'] == post_path
    raise "expected the second user's comment-edit attempt to be redirected back to the post, got " \
          "#{forbidden_comment_edit.code} Location=#{forbidden_comment_edit['location']}"
  end

  forbidden_comment_update_body = URI.encode_www_form('comment[body]' => 'hijacked', '_method' => 'PATCH',
                                                        'authenticity_token' => token)
  forbidden_comment_update = http.post(comment_edit_path, forbidden_comment_update_body,
                                        'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{comment_edit_path} with _method=PATCH as a DIFFERENT user -> #{forbidden_comment_update.code} " \
       "Location=#{forbidden_comment_update['location']}"
  unless forbidden_comment_update.code == '302' && forbidden_comment_update['location'] == post_path
    raise "expected the second user's comment-update attempt to be redirected back to the post, got " \
          "#{forbidden_comment_update.code} Location=#{forbidden_comment_update['location']}"
  end

  still_owned_comment = http.get(post_path, 'Cookie' => cookie)
  raise 'the comment must not be hijacked by an unauthorized update attempt' if still_owned_comment.body.include?('hijacked')
  raise 'the comment should still show its previous edit' unless still_owned_comment.body.include?('Nice post, tab A won!')
  puts "GET #{post_path} -> comment survives, still owned by its original author"

  still_there = http.get(post_path, 'Cookie' => cookie)
  raise 'the post must survive an unauthorized delete attempt by another user' unless still_there.code == '200'
  raise 'the post content should still be there after the forbidden attempt' unless still_there.body.include?('Hello from Facet')
  puts "GET #{post_path} -> #{still_there.code} (post survives, still owned by its author)"

  puts '-' * 40
  puts "comment moderation visibility: reader2 (still signed in) posts a brand new comment, which " \
       'defaults to pending and so is invisible to a stranger until the post owner approves it'
  pending_comment_body = URI.encode_www_form(
    'comment[author]' => 'Reader2', 'comment[body]' => 'A brand new pending remark', 'authenticity_token' => token
  )
  pending_comment = http.post("/posts/#{post_id}/comments", pending_comment_body,
                               'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected reader2's new comment to redirect, got #{pending_comment.code}" unless pending_comment.code == '302'
  pending_comment_cookie = cookie_from(pending_comment)
  cookie = pending_comment_cookie unless pending_comment_cookie.empty?
  puts "POST /posts/#{post_id}/comments as reader2 -> #{pending_comment.code} (status defaults to pending)"

  own_pending_view = http.get(post_path, 'Cookie' => cookie)
  unless own_pending_view.body.include?('A brand new pending remark') && own_pending_view.body.include?('Pending approval')
    raise "a comment's own author should see it, badge and all, while it's still pending"
  end
  pending_comment_id = own_pending_view.body[/id="comment-(\d+)"/, 1]
  raise "could not find reader2's new comment id on the post page" unless pending_comment_id
  puts "GET #{post_path} as reader2 -> sees own pending comment with its 'Pending approval' badge"

  stranger_view = http.get(post_path)
  if stranger_view.body.include?('A brand new pending remark')
    raise 'a signed-out stranger must not see a pending comment that is neither theirs nor on their own post'
  end
  puts "GET #{post_path} signed out (no cookie at all) -> pending comment from another user stays hidden " \
       '(Comment.visible_to)'

  sign_back_in_body = URI.encode_www_form(
    'user[email]' => 'writer@example.com', 'user[password]' => 'correct horse battery staple',
    'user[remember_me]' => '1', 'authenticity_token' => token
  )
  sign_back_in = http.post('/session.json', sign_back_in_body,
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie,
                            'User-Agent' => 'DeviceA-Desktop/1.0')
  raise "expected the original author to sign back in via JSON, got #{sign_back_in.code}" unless sign_back_in.code == '200'
  sign_back_in_json = JSON.parse(sign_back_in.body)
  raise 'JSON sign-in response should carry the signed-in user email' unless sign_back_in_json['email'] == 'writer@example.com'
  puts "POST /session.json (sign in, remember_me=1) -> #{sign_back_in.code}, signed in as #{sign_back_in_json['email']} (device A)"
  fresh_cookie = cookie_from(sign_back_in)
  cookie = fresh_cookie unless fresh_cookie.empty?

  remember_session_token_a = cookie_value_from(sign_back_in, 'remember_session_token')
  raise 'expected sign_in(remember: true) to set a remember_session_token cookie' unless remember_session_token_a
  puts "  Set-Cookie also carried #{remember_session_token_a[/\A[^=]+/]}=... (device A's own LoginSession row)"

  remember_only_trash = http.get('/posts/trash', 'Cookie' => remember_session_token_a)
  unless remember_only_trash.code == '200'
    raise "expected the remember-me cookie alone to authenticate GET /posts/trash, got #{remember_only_trash.code}"
  end
  puts "GET /posts/trash using ONLY device A's remember-me cookie (no session cookie) -> 200"
  unless cookie_value_from(remember_only_trash, 'facet.session')
    raise 'expected falling back to the remember cookie to also repopulate a fresh session cookie'
  end
  puts '  response also carried a fresh facet.session cookie (fast path repopulated for the next request)'

  puts '-' * 40
  puts 'multi-device remember me: TWO more entirely independent browsers (own cookie jars, own CSRF tokens, ' \
       'no cookie ever shared with device A) sign in as the SAME writer account with remember_me=1'
  remember_session_token_b = sign_in_new_device(http, 'device B', user_agent: 'DeviceB-Mobile/2.0')
  remember_session_token_c = sign_in_new_device(http, 'device C', user_agent: 'DeviceC-Tablet/3.0')

  devices_page = http.get('/login_sessions', 'Cookie' => cookie)
  raise "expected device A to load /login_sessions, got #{devices_page.code}" unless devices_page.code == '200'
  other_ids = devices_page.body.scan(/class="login-session" id="login-session-(\d+)"/).flatten
  unless other_ids.size == 2 && devices_page.body.include?('login-session current')
    raise "expected device A's own row plus exactly 2 OTHER remembered devices (B and C), got #{other_ids.inspect}"
  end
  puts "GET /login_sessions as device A -> 200, lists itself (\"this device\") plus #{other_ids.size} other " \
       'remembered devices (B and C) - Facet::Authenticatable#other_login_sessions'

  %w[DeviceA-Desktop/1.0 DeviceB-Mobile/2.0 DeviceC-Tablet/3.0].each do |ua|
    raise "expected /login_sessions to show \"#{ua}\" (Authenticatable's captured user_agent)" unless devices_page.body.include?(ua)
  end
  if devices_page.body.include?(Facet::I18n.t('login_sessions.unknown_user_agent'))
    raise 'expected every device row to have a captured user_agent, none should fall back to "unknown browser"'
  end
  puts '  every row shows its own captured User-Agent (LoginSessionsController#device_detail_for) - none falls ' \
       'back to "unknown browser", proving Authenticatable#remember_user_with_session really persisted it, not ' \
       'just accepted the column silently'

  revoke_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  revoke_one = http.post("/login_sessions/#{other_ids.first}", revoke_body,
                          'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless revoke_one.code == '302' && revoke_one['location'].to_s.end_with?('/login_sessions')
    raise "expected device A revoking one other device to redirect back to /login_sessions, got #{revoke_one.code}"
  end
  puts "POST /login_sessions/#{other_ids.first} with _method=DELETE (device A revokes ONE other device) -> " \
       "#{revoke_one.code}"

  b_survives = http.get('/posts/trash', 'Cookie' => remember_session_token_b).code == '200'
  c_survives = http.get('/posts/trash', 'Cookie' => remember_session_token_c).code == '200'
  unless [b_survives, c_survives].count(true) == 1
    raise "expected revoking exactly one LoginSession row to break exactly one of B/C's remember cookies, " \
          "got device B survives=#{b_survives} device C survives=#{c_survives}"
  end
  survivor_cookie = b_survives ? remember_session_token_b : remember_session_token_c
  puts '  the revoked device\'s remember-me cookie is now dead (falls through to sign-in), the untouched ' \
       'device\'s cookie still authenticates - per-device revocation, unlike sign_out rotating one shared column'

  sign_out_others = http.post('/login_sessions/sign_out_others',
                               URI.encode_www_form('authenticity_token' => token),
                               'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless sign_out_others.code == '302' && sign_out_others['location'].to_s.end_with?('/login_sessions')
    raise "expected sign_out_all_other_sessions to redirect back to /login_sessions, got #{sign_out_others.code}"
  end
  puts "POST /login_sessions/sign_out_others as device A -> #{sign_out_others.code} " \
       '(Authenticatable#sign_out_all_other_sessions revokes every remaining OTHER device in one call)'

  survivor_after_bulk = http.get('/posts/trash', 'Cookie' => survivor_cookie)
  unless survivor_after_bulk.code == '302' && survivor_after_bulk['location'].to_s.end_with?('/session/new')
    raise "expected the last surviving other device to be signed out after sign_out_others, got #{survivor_after_bulk.code}"
  end
  puts '  the last surviving OTHER device is now signed out too -> 302 to sign-in'

  device_a_still_works = http.get('/posts/trash', 'Cookie' => remember_session_token_a)
  unless device_a_still_works.code == '200'
    raise "expected device A's OWN remember cookie to survive sign_out_all_other_sessions, got #{device_a_still_works.code}"
  end
  puts "  device A's OWN remember-me cookie still works -> 200 (sign_out_all_other_sessions never touches the " \
       'caller\'s own session)'

  moderator_view = http.get(post_path, 'Cookie' => cookie)
  unless moderator_view.body.include?('A brand new pending remark')
    raise "the post's own author (moderator) should see a pending comment even before approving it"
  end
  puts "GET #{post_path} as the post's author -> sees reader2's still-pending comment (moderator sees " \
       'everything on their own post, CommentPolicy#approve?/#reject? check the POST owner)'

  puts '-' * 40
  puts "checking AccountController#moderation (GET /account/moderation) - a cross-post moderation queue, " \
       "gathering reader2's still-pending comment onto ONE page instead of the author having to open every " \
       "post separately, and confirming add_index :posts, :user_id (db/migrate/20260907000009) plus the " \
       "existing add_index :comments, :post_id (.../20260907000005) answer it without a single full table scan"
  moderation_log_offset = File.size(log_path)
  moderation_queue = http.get('/account/moderation', 'Cookie' => cookie)
  raise "expected GET /account/moderation to succeed, got #{moderation_queue.code}" unless moderation_queue.code == '200'
  unless moderation_queue.body.include?('A brand new pending remark') && moderation_queue.body.include?('Hello from Facet')
    raise "expected the moderation queue to list reader2's pending comment alongside its post's title"
  end
  moderation_log_lines = File.read(log_path)[moderation_log_offset..].to_s
  if moderation_log_lines.include?('operation="SELECT" table="posts"') || moderation_log_lines.include?('operation="SELECT" table="comments"')
    raise 'expected AccountController#moderation (current_user.posts then Comment.pending.where(post_id: ...)) ' \
          'to resolve entirely through indexes, not a full table scan'
  end
  unless moderation_log_lines.include?('operation="SELECT INDEX" table="posts" columns=["user_id"]')
    raise 'expected current_user.posts (owned post ids) to hit the posts.user_id index'
  end
  unless moderation_log_lines.include?('operation="SELECT INDEX IN" table="comments" columns=["post_id"]')
    raise 'expected Comment.pending.where(post_id: owned_post_ids) to hit the comments.post_id index via an ' \
          'IN-list lookup, not a scan'
  end
  puts '  GET /account/moderation -> 200, sql.facet log shows SELECT INDEX on posts.user_id then SELECT INDEX ' \
       'IN on comments.post_id - zero full scans across both index-backed steps'

  reader2_forbidden_approve_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  reader2_forbidden_approve = http.post(
    "/posts/#{post_id}/comments/#{pending_comment_id}/approve", reader2_forbidden_approve_body,
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => pending_comment_cookie
  )
  unless reader2_forbidden_approve.code == '302' && reader2_forbidden_approve['location'] == post_path
    raise 'a non-owner (even the comment author themself) must not be able to approve their own comment, got ' \
          "#{reader2_forbidden_approve.code} Location=#{reader2_forbidden_approve['location']}"
  end
  puts "POST /posts/#{post_id}/comments/#{pending_comment_id}/approve as reader2 (not the post's author) -> " \
       "#{reader2_forbidden_approve.code} (CommentPolicy#approve? denied it, forbidden redirect back to the post)"

  approve_pending_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  approve_pending = http.post(
    "/posts/#{post_id}/comments/#{pending_comment_id}/approve", approve_pending_body,
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  raise "expected the moderator's approval to redirect, got #{approve_pending.code}" unless approve_pending.code == '302'
  approve_pending_cookie = cookie_from(approve_pending)
  cookie = approve_pending_cookie unless approve_pending_cookie.empty?
  puts "POST /posts/#{post_id}/comments/#{pending_comment_id}/approve as the post's author -> #{approve_pending.code}"

  stranger_view_after_approval = http.get(post_path)
  unless stranger_view_after_approval.body.include?('A brand new pending remark')
    raise "an approved comment should now be visible to a signed-out stranger too"
  end
  if stranger_view_after_approval.body.include?('Pending approval')
    raise 'an approved comment must no longer carry the pending badge'
  end
  puts "GET #{post_path} signed out -> reader2's comment is now visible to everyone, no more pending badge"

  moderation_queue_after_approval = http.get('/account/moderation', 'Cookie' => cookie)
  raise "expected GET /account/moderation to succeed, got #{moderation_queue_after_approval.code}" unless moderation_queue_after_approval.code == '200'
  if moderation_queue_after_approval.body.include?('A brand new pending remark')
    raise 'an approved comment must no longer show up in the moderation queue'
  end
  puts 'GET /account/moderation after approval -> the now-approved comment is no longer listed'

  puts '-' * 40
  puts 'comment moderation, the other outcome: reader2 posts a second comment and the post\'s ' \
       'author REJECTS it instead of approving it'
  second_pending_body = URI.encode_www_form(
    'comment[author]' => 'Reader2', 'comment[body]' => 'A remark that will get rejected', 'authenticity_token' => token
  )
  second_pending = http.post("/posts/#{post_id}/comments", second_pending_body,
                              'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => pending_comment_cookie)
  raise "expected reader2's second comment to redirect, got #{second_pending.code}" unless second_pending.code == '302'
  puts "POST /posts/#{post_id}/comments as reader2 -> #{second_pending.code} (status defaults to pending again)"

  reader2_second_view = http.get(post_path, 'Cookie' => pending_comment_cookie)
  unless reader2_second_view.body.include?('A remark that will get rejected') && reader2_second_view.body.include?('Pending approval')
    raise "reader2 should see their own new comment pending, badge and all"
  end
  rejectable_comment_id = reader2_second_view.body[/id="comment-(\d+)"/, 1]
  raise "could not find reader2's second comment id on the post page" unless rejectable_comment_id

  reader2_forbidden_reject_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  reader2_forbidden_reject = http.post(
    "/posts/#{post_id}/comments/#{rejectable_comment_id}/reject", reader2_forbidden_reject_body,
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => pending_comment_cookie
  )
  unless reader2_forbidden_reject.code == '302' && reader2_forbidden_reject['location'] == post_path
    raise 'a non-owner (even the comment author themself) must not be able to reject their own comment, got ' \
          "#{reader2_forbidden_reject.code} Location=#{reader2_forbidden_reject['location']}"
  end
  puts "POST /posts/#{post_id}/comments/#{rejectable_comment_id}/reject as reader2 (not the post's author) -> " \
       "#{reader2_forbidden_reject.code} (CommentPolicy#reject? denied it, forbidden redirect back to the post)"

  reject_pending_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  reject_pending = http.post(
    "/posts/#{post_id}/comments/#{rejectable_comment_id}/reject", reject_pending_body,
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  raise "expected the moderator's rejection to redirect, got #{reject_pending.code}" unless reject_pending.code == '302'
  reject_pending_cookie = cookie_from(reject_pending)
  cookie = reject_pending_cookie unless reject_pending_cookie.empty?
  puts "POST /posts/#{post_id}/comments/#{rejectable_comment_id}/reject as the post's author -> #{reject_pending.code}"

  stranger_view_after_rejection = http.get(post_path)
  if stranger_view_after_rejection.body.include?('A remark that will get rejected')
    raise 'a rejected comment must stay invisible to a signed-out stranger, same as a pending one'
  end
  puts "GET #{post_path} signed out -> the rejected comment stays hidden (Comment.visible_to only " \
       'admits approved comments or the viewer\'s own)'

  author_view_after_rejection = http.get(post_path, 'Cookie' => pending_comment_cookie)
  unless author_view_after_rejection.body.include?('A remark that will get rejected') &&
         author_view_after_rejection.body.include?('Rejected')
    raise "the rejected comment's own author should still see it, now carrying the \"Rejected\" badge"
  end
  puts "GET #{post_path} as reader2 (the comment's own author) -> sees their own rejected comment, " \
       'badge and all (Comment.visible_to admits their own regardless of status)'

  moderator_view_after_rejection = http.get(post_path, 'Cookie' => cookie)
  reject_path = "/posts/#{post_id}/comments/#{rejectable_comment_id}/reject"
  approve_path = "/posts/#{post_id}/comments/#{rejectable_comment_id}/approve"
  raise 'a rejected comment must no longer offer the moderator a Reject button' if moderator_view_after_rejection.body.include?(reject_path)
  unless moderator_view_after_rejection.body.include?(approve_path)
    raise 'a rejected comment should still offer the moderator an Approve button (it can still be reconsidered)'
  end
  puts "GET #{post_path} as the post's author -> the Reject button for this comment is gone, Approve is still " \
       "offered (Comment#rejected? flips exactly one of the two buttons)"

  delete_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  destroy = http.post(post_path, delete_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST #{post_path} with _method=DELETE -> #{destroy.code} Location=#{destroy['location']}"

  gone = http.get(post_path, 'Cookie' => cookie)
  puts "GET #{post_path} after delete -> #{gone.code} (expected 404, dependent comment cascaded away too)"
  raise 'post should be gone after destroy' unless gone.code == '404'
  raise "soft-deleted post's cover file should NOT have been removed: #{cover_file}" unless File.exist?(cover_file)
  puts "soft-deleted post kept its cover file on disk (#{File.basename(cover_file)}), only stamped deleted_at"

  unless Like.where(likeable_type: 'Post', likeable_id: post_row_id).count.zero?
    raise "trashing the post should have hidden its own Like row from the default scope"
  end
  unless Like.only_deleted.where(likeable_type: 'Post', likeable_id: post_row_id).count == 1
    raise "trashing the post should have soft-deleted (not removed) its own Like row"
  end
  unless Comment.where(id: comment_id.to_i).count.zero?
    raise "trashing the post should have hidden its cascaded comment from the default scope"
  end
  unless Comment.only_deleted.where(id: comment_id.to_i).count == 1
    raise "trashing the post should have soft-deleted (not removed) its cascaded comment"
  end
  unless Like.only_deleted.where(likeable_type: 'Comment', likeable_id: comment_id.to_i).count == 1
    raise "trashing the post should have recursively soft-deleted its cascaded comment's own Like too"
  end
  puts 'Like/Comment rows under the trashed post are hidden but not gone (only_deleted still finds them, ' \
       'polymorphic dependent: :destroy through a soft-delete)'

  trash_page = http.get('/posts/trash', 'Cookie' => cookie)
  unless trash_page.code == '200' && trash_page.body.include?("id=\"post-#{post_id}\"")
    raise "expected the post's own author to see it in their trash, got #{trash_page.code}"
  end
  puts "GET /posts/trash as the post's author -> 200, trashed post listed"

  restore_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  restore = http.post("/posts/#{post_id}/restore", restore_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless restore.code == '302' && restore['location'].to_s.end_with?('/posts/trash')
    raise "expected restore to redirect back to the trash, got #{restore.code} Location=#{restore['location']}"
  end
  puts "POST /posts/#{post_id}/restore with _method=PATCH -> #{restore.code} Location=#{restore['location']}"

  restored = http.get(post_path, 'Cookie' => cookie)
  raise "restored post should be reachable again, got #{restored.code}" unless restored.code == '200'
  raise 'restored post should still reference its original cover file' unless restored.body.include?(File.basename(cover_file))
  puts "GET #{post_path} after restore -> 200, original cover still referenced"

  trash_page_after_restore = http.get('/posts/trash', 'Cookie' => cookie)
  if trash_page_after_restore.body.include?("id=\"post-#{post_id}\"")
    raise 'a restored post must no longer show up in the trash'
  end
  puts 'GET /posts/trash after restore -> the restored post is no longer listed'

  unless Comment.where(id: comment_id.to_i).count == 1
    raise 'restore(recursive: true) should have brought the cascaded comment back too'
  end
  unless Like.where(likeable_type: 'Post', likeable_id: post_row_id).count == 1
    raise "restore(recursive: true) should have brought the post's own Like back too"
  end
  unless Like.where(likeable_type: 'Comment', likeable_id: comment_id.to_i).count == 1
    raise "restore(recursive: true) should have recursively restored the comment's own Like too"
  end
  raise 'restoring a comment should have re-incremented comments_count' unless Post.find_by!(slug: post_id).comments_count.positive?
  unless Post.find_by!(slug: post_id).likes_count == 1
    raise "Post#after_restore counter_cache hook should have re-incremented likes_count for the post's own Like"
  end
  unless Comment.find(comment_id).likes_count == 1
    raise "cascaded Comment#after_restore counter_cache hook should have re-incremented its own likes_count too"
  end
  puts 'restore(recursive: true) brought the comment AND both Likes (post-level and comment-level) back ' \
       '(Associable#cascade_restore_dependent_associations recursing two levels deep, counter_cache re-synced)'

  puts '-' * 40
  puts 'deleting and restoring ONE comment on its own, independent of its (live, not trashed) post - ' \
       'CommentsController#trash/#restore, a flat top-level page (not nested under /posts/:post_id)'
  comments_count_before_solo_delete = Post.find_by!(slug: post_id).comments_count
  solo_delete_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  solo_delete = http.post(comment_edit_path, solo_delete_body,
                           'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless solo_delete.code == '302' && solo_delete['location'] == post_path
    raise "expected the solo comment delete to redirect back to the post, got #{solo_delete.code}"
  end
  puts "POST #{comment_edit_path} with _method=DELETE -> #{solo_delete.code} (soft-deleted, Comment#acts_as_paranoid)"

  post_after_solo_delete = http.get(post_path, 'Cookie' => cookie)
  raise 'the post itself must stay reachable when only one of its comments is deleted' unless post_after_solo_delete.code == '200'
  if post_after_solo_delete.body.include?("id=\"comment-#{comment_id}\"")
    raise 'the soft-deleted comment should no longer show up on its (still live) post'
  end
  unless Post.find_by!(slug: post_id).comments_count == comments_count_before_solo_delete - 1
    raise 'deleting one comment should decrement its post comments_count, independent of any post-level trash'
  end
  puts "GET #{post_path} -> post still live (200), the deleted comment is gone from it, comments_count decremented " \
       '(nothing about the POST changed - Post itself was never touched)'

  unless Like.where(likeable_type: 'Comment', likeable_id: comment_id.to_i).count.zero?
    raise "deleting the comment should have cascaded (soft-deleted) its own Like via dependent: :destroy"
  end
  unless Like.only_deleted.where(likeable_type: 'Comment', likeable_id: comment_id.to_i).count == 1
    raise "the comment's cascaded Like should be soft-deleted (only_deleted), not gone for good"
  end

  comments_trash_page = http.get('/comments/trash', 'Cookie' => cookie)
  unless comments_trash_page.code == '200' && comments_trash_page.body.include?("id=\"comment-#{comment_id}\"")
    raise "expected the comment author's own trash to list it, got #{comments_trash_page.code}"
  end
  unless comments_trash_page.body.include?('Hello from Facet')
    raise "the comments trash page should label each row with its (still live) post's title"
  end
  puts "GET /comments/trash -> 200, deleted comment listed with a link back to its still-live post"

  solo_restore_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  solo_restore = http.post("/comments/#{comment_id}/restore", solo_restore_body,
                            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  unless solo_restore.code == '302' && solo_restore['location'].to_s.end_with?('/comments/trash')
    raise "expected the solo comment restore to redirect back to /comments/trash, got #{solo_restore.code}"
  end
  puts "POST /comments/#{comment_id}/restore with _method=PATCH -> #{solo_restore.code} Location=#{solo_restore['location']}"

  post_after_solo_restore = http.get(post_path, 'Cookie' => cookie)
  unless post_after_solo_restore.body.include?("id=\"comment-#{comment_id}\"")
    raise 'the restored comment should be back on its post'
  end
  unless Post.find_by!(slug: post_id).comments_count == comments_count_before_solo_delete
    raise 'restoring the comment should re-increment comments_count back to what it was'
  end
  unless Like.where(likeable_type: 'Comment', likeable_id: comment_id.to_i).count == 1
    raise "restore(recursive: true) inside CommentsController#restore should have brought the comment's own Like back too"
  end
  puts "GET #{post_path} -> the restored comment (and its Like) are back, comments_count restored"

  comments_trash_after_restore = http.get('/comments/trash', 'Cookie' => cookie)
  if comments_trash_after_restore.body.include?("id=\"comment-#{comment_id}\"")
    raise 'a restored comment must no longer show up in /comments/trash'
  end
  puts 'GET /comments/trash after restore -> the restored comment is no longer listed'

  owner_id = Comment.find(comment_id.to_i).user_id
  my_comments_last_page = (Comment.where(user_id: owner_id).count / 10.0).ceil
  my_comments_page = http.get("/account/comments?page=#{my_comments_last_page}", 'Cookie' => cookie)
  unless my_comments_page.code == '200' && my_comments_page.body.include?("id=\"comment-#{comment_id}\"")
    raise "expected /account/comments (page #{my_comments_last_page}) to list the signed-in user's own " \
          "restored comment, got #{my_comments_page.code}"
  end
  unless my_comments_page.body.include?('Hello from Facet')
    raise "the account comments page should label each row with its post's title, same as /comments/trash"
  end
  puts "GET /account/comments -> 200, the signed-in user's own comment listed with its post's title"

  puts '-' * 40
  logout_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  logout = http.post('/session.json', logout_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  puts "POST /session.json with _method=DELETE (sign out) -> #{logout.code}"
  raise "expected JSON sign-out to return 200, got #{logout.code}" unless logout.code == '200'
  raise 'JSON sign-out response should carry a message' unless JSON.parse(logout.body)['message']
  signed_out_cookie = cookie_from(logout)
  cookie = signed_out_cookie unless signed_out_cookie.empty?

  stale_remember_attempt = http.get('/posts/trash', 'Cookie' => remember_session_token_a)
  unless stale_remember_attempt.code == '302' && stale_remember_attempt['location'].to_s.end_with?('/session/new')
    raise "expected the OLD remember-me cookie to stop working after sign-out, got #{stale_remember_attempt.code}"
  end
  puts "GET /posts/trash with device A's now-stale remember-me cookie after sign-out -> " \
       "#{stale_remember_attempt.code} (sign_out destroyed its LoginSession row, so a captured old cookie is dead)"

  blocked_again = http.post(
    '/posts', URI.encode_www_form('post[title]' => 'still blocked', 'authenticity_token' => token),
    'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie
  )
  puts "POST /posts after sign out -> #{blocked_again.code} Location=#{blocked_again['location']}"
  unless blocked_again.code == '302' && blocked_again['location'].to_s.end_with?('/session/new')
    raise "expected post#create to require authentication again after sign-out, got #{blocked_again.code}"
  end

  puts '-' * 40
  puts 'hammering POST /session with bad credentials to exercise Facet::Middleware::RateLimiting'
  login_attempt_body = URI.encode_www_form(
    'user[email]' => 'writer@example.com', 'user[password]' => 'wrong password', 'authenticity_token' => token
  )
  6.times do |i|
    path = i.zero? ? '/session.json' : '/session'
    attempt = http.post(path, login_attempt_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                    'Cookie' => cookie)
    expected = if i.zero? then '401'
               elsif i == 1 then '422'
               else '429'
               end
    puts "  attempt #{i + 1}: POST #{path} -> #{attempt.code} (expected #{expected})"
    raise "login attempt #{i + 1}: expected #{expected}, got #{attempt.code}" unless attempt.code == expected
    if i.zero?
      error = JSON.parse(attempt.body)['errors'].first
      raise 'expected the JSON login rejection to point at the password attribute' unless error['source']['pointer'] == '/data/attributes/password'
    end
    raise 'the blocked attempt should carry a Retry-After header' if i == 2 && attempt['retry-after'].nil?
  end

  puts '-' * 40
  puts 'hammering POST /users to exercise the signup throttle (limit 3/60s per IP)'
  signup_attempt_body = URI.encode_www_form(
    'user[email]' => 'writer@example.com', 'user[password]' => 'irrelevant',
    'user[password_confirmation]' => 'irrelevant', 'authenticity_token' => token
  )
  2.times do |i|
    path = i.zero? ? '/users.json' : '/users'
    attempt = http.post(path, signup_attempt_body, 'Content-Type' => 'application/x-www-form-urlencoded',
                                                     'Cookie' => cookie)
    expected = i.zero? ? '422' : '429'
    puts "  attempt #{i + 1}: POST #{path} -> #{attempt.code} (expected #{expected})"
    raise "signup attempt #{i + 1}: expected #{expected}, got #{attempt.code}" unless attempt.code == expected
    if i.zero?
      error = JSON.parse(attempt.body)['errors'].first
      raise 'expected the JSON signup rejection to point at the email attribute' unless error['source']['pointer'] == '/data/attributes/email'
    end
    raise 'the blocked attempt should carry a Retry-After header' if i == 1 && attempt['retry-after'].nil?
  end
end

puts '-' * 40
puts "checking that add_index :users, :email, unique: true (db/migrate/20260907000002_add_index_on_users_email.rb) is a REAL storage-level constraint, not just the app-level validates :email, uniqueness: true above"
existing_writer = User.find_by(email: 'writer@example.com')
raise 'expected the writer@example.com user created earlier in this demo to still exist' unless existing_writer
users_count_before_bypass = User.count
begin
  User.store.insert(User.table_name, 'email' => existing_writer[:email])
  raise 'expected the unique index on users.email to reject a duplicate row inserted directly through Store#insert, bypassing Model#valid? entirely'
rescue Facet::Orm::Store::UniqueConstraintViolation => e
  puts "  Store#insert with a duplicate encrypted email, bypassing Model validation entirely -> #{e.class}: #{e.message}"
end
raise 'the rejected bypass insert must not have left a phantom row behind' unless User.count == users_count_before_bypass

puts '-' * 40
puts 'checking examples/blog/log/development.log for real Instrumentation::LogSubscriber output'
new_log_lines = File.read(log_path)[log_offset_before_requests..].to_s
%w[sql.facet render_template.facet process_action.facet perform_job.facet deliver_mail.facet].each do |event_name|
  raise "expected at least one #{event_name} line in #{log_path}" unless new_log_lines.include?("  #{event_name} (")
end
unless new_log_lines.include?('table="posts"')
  raise "expected a sql.facet line touching the posts table in #{log_path}"
end
unless new_log_lines.include?('path="/"')
  raise "expected a process_action.facet line for the homepage in #{log_path}"
end
unless new_log_lines.include?('job_class="Facet::Mailer::DeliveryJob"')
  raise "expected a perform_job.facet line for the mailer delivery job in #{log_path}"
end
unless new_log_lines.include?('deliver_mail.facet') && new_log_lines.include?('delivery_method=:test')
  raise "expected a deliver_mail.facet line for the notification email in #{log_path}"
end
puts "  log grew by #{new_log_lines.lines.count} lines, sql/render/process_action/perform_job/deliver_mail all present"

server.stop
puts '-' * 40
puts 'blog demo done (process about to exit; data stays on disk for the restart check)'
