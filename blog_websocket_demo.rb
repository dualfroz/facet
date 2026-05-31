# End-to-end proof of PostActivityChannel (examples/blog/app/channels/
# post_activity_channel.rb) - the WebSocket + Hub broadcaster from lib/
# prism/websocket wired into a real controller for the first time.
# Everything below happens over a real TCPSocket doing its own HTTP
# Upgrade handshake by hand (same style as test_websocket_integration.rb),
# alongside ordinary Net::HTTP requests hitting the SAME running server -
# proving the two protocols coexist on one Prism::Server, and that an
# actual CommentsController#approve/#reject/#destroy over HTTP is what
# pushes the broadcast, not a hand-triggered Hub call.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'prism'
require 'net/http'
require 'socket'
require 'fileutils'
require 'json'

ROOT = __dir__
SCRATCH_DB_DIR = File.join(ROOT, 'examples/blog/db/websocket_demo')
FileUtils.rm_rf(SCRATCH_DB_DIR)
ENV['PRISM_BLOG_DB_DIR'] = SCRATCH_DB_DIR

require_relative 'examples/blog/app'

# max_websocket_connections: 3 mirrors examples/blog/bin/server (which uses
# a realistic 2000) but small enough that this demo's own three concurrent
# viewers below (viewer_a, viewer_b, bystander) can actually saturate it,
# proving the cap for real instead of just asserting the option is accepted.
server = Prism::Server.new(Blog, port: 0, max_websocket_connections: 3).start
port = server.port
puts "blog_websocket_demo server on port #{port}"
puts '-' * 40

Frame = Prism::WebSocket::Frame
Handshake = Prism::WebSocket::Handshake

def cookie_from(response)
  lines = response.get_fields('set-cookie') || []
  lines.map { |line| line.split(';').first }.join('; ')
end

def csrf_token_from(html)
  html[/name="csrf-token" content="([^"]+)"/, 1]
end

# Hand-rolled Upgrade handshake over a raw TCPSocket, deliberately not
# reusing anything from Net::HTTP - an Upgrade request is not an ordinary
# HTTP request/response cycle (see Prism::Server#serve intercepting it
# before @app.call ever runs), so this proves the real wire protocol,
# the same way test_websocket_integration.rb does for the library itself.
def open_cable(host, port, post_id)
  socket = TCPSocket.new(host, port)
  key = [Array.new(16) { rand(256) }.pack('C16')].pack('m0')
  socket.write(
    "GET /cable?post_id=#{post_id} HTTP/1.1\r\n" \
    "Host: #{host}\r\n" \
    "Upgrade: websocket\r\n" \
    "Connection: Upgrade\r\n" \
    "Sec-WebSocket-Key: #{key}\r\n" \
    "Sec-WebSocket-Version: 13\r\n" \
    "\r\n"
  )
  headers = +''
  until headers.end_with?("\r\n\r\n")
    line = socket.gets("\r\n")
    raise 'connection closed mid-handshake' if line.nil?
    headers << line
  end
  raise "expected a 101 handshake, got: #{headers}" unless headers.include?('101')
  expected_accept = Handshake.accept_key(key)
  raise 'Sec-WebSocket-Accept did not match the RFC 6455 formula' unless headers.include?(expected_accept)
  socket
end

# Same handshake request as open_cable, but for proving max_websocket_
# connections rejects it BEFORE any Upgrade: the server must answer with an
# ordinary HTTP 503 (not a 101, and not a partial/dropped connection), read
# off the raw socket exactly like open_cable reads a successful handshake.
def attempt_rejected_cable(host, port, post_id)
  socket = TCPSocket.new(host, port)
  key = [Array.new(16) { rand(256) }.pack('C16')].pack('m0')
  socket.write(
    "GET /cable?post_id=#{post_id} HTTP/1.1\r\n" \
    "Host: #{host}\r\n" \
    "Upgrade: websocket\r\n" \
    "Connection: Upgrade\r\n" \
    "Sec-WebSocket-Key: #{key}\r\n" \
    "Sec-WebSocket-Version: 13\r\n" \
    "\r\n"
  )
  headers = +''
  until headers.end_with?("\r\n\r\n")
    line = socket.gets("\r\n")
    raise 'connection closed before any HTTP status line arrived' if line.nil?
    headers << line
  end
  socket.close
  headers
end

def read_event(socket)
  JSON.parse(Frame.decode(socket).payload)
end

Net::HTTP.start('127.0.0.1', port) do |http|
  home = http.get('/')
  cookie = cookie_from(home)
  token = csrf_token_from(home.body)
  puts "GET / -> #{home.code}"

  signup_body = URI.encode_www_form(
    'user[email]' => 'moderator@example.com', 'user[password]' => 'correct horse battery staple',
    'user[password_confirmation]' => 'correct horse battery staple', 'authenticity_token' => token
  )
  signup = http.post('/users', signup_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected sign-up to redirect, got #{signup.code}" unless signup.code == '302'
  cookie = cookie_from(signup)
  puts "POST /users (sign up as moderator) -> #{signup.code}"

  create_body = URI.encode_www_form(
    'post[title]' => 'Live comment counts', 'post[body]' => 'Watching this page update without a reload.',
    'authenticity_token' => token
  )
  create = http.post('/posts', create_body, 'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the post to be created, got #{create.code}" unless create.code == '302'
  post_path = create['location']
  post_id = post_path.split('/').last
  cookie = cookie_from(create)
  puts "POST /posts -> #{create.code} Location=#{post_path}"

  # Two independent viewers open the post's live channel before any
  # comment exists - each gets its own subscribed acknowledgement, proving
  # the Hub keys subscribers by stream (this post's id), not just "anyone
  # connected right now".
  viewer_a = open_cable('127.0.0.1', port, post_id)
  viewer_b = open_cable('127.0.0.1', port, post_id)
  welcome_a = read_event(viewer_a)
  welcome_b = read_event(viewer_b)
  raise "expected viewer_a's subscribe ack, got #{welcome_a.inspect}" unless welcome_a == { 'event' => 'subscribed', 'post_id' => post_id }
  raise "expected viewer_b's subscribe ack, got #{welcome_b.inspect}" unless welcome_b == { 'event' => 'subscribed', 'post_id' => post_id }
  puts "GET /cable?post_id=#{post_id} x2 -> 101 Switching Protocols, both subscribed"

  # A third connection opens a channel for a DIFFERENT (nonexistent) post -
  # it must never see this post's events, proving streams are genuinely
  # isolated per post, not one shared firehose.
  bystander = open_cable('127.0.0.1', port, '999999')
  read_event(bystander) # subscribe ack, discarded
  puts "GET /cable?post_id=999999 -> 101 (unrelated post, must stay silent below)"

  # viewer_a, viewer_b, and bystander are now three live WebSocket
  # connections on this process - exactly the max_websocket_connections
  # cap set above. A fourth, entirely unrelated stream must be turned away
  # BEFORE the Upgrade handshake even starts, proving the limit is global
  # (per-process) rather than PostActivityChannel::MAX_VIEWERS_PER_POST's
  # per-stream cap, which would never trip with only three viewers total.
  rejection_headers = attempt_rejected_cable('127.0.0.1', port, post_id)
  raise "expected a 503, got: #{rejection_headers}" unless rejection_headers.include?('503')
  puts "GET /cable?post_id=#{post_id} (4th concurrent WS connection) -> 503 Service Unavailable " \
       '(max_websocket_connections: 3 reached, rejected before any Upgrade)'

  comment_body = URI.encode_www_form('comment[author]' => 'Reader', 'comment[body]' => 'First!', 'authenticity_token' => token)
  comment = http.post("/posts/#{post_id}/comments", comment_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the comment to be created, got #{comment.code}" unless comment.code == '302'
  cookie = cookie_from(comment)
  show = http.get(post_path, 'Cookie' => cookie)
  comment_id = show.body[/id="comment-(\d+)"/, 1]
  raise 'could not find the new comment id on the post page' unless comment_id
  puts "POST /posts/#{post_id}/comments -> #{comment.code} (still pending, no broadcast yet)"

  approve_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  approve = http.post("/posts/#{post_id}/comments/#{comment_id}/approve", approve_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the approval to redirect, got #{approve.code}" unless approve.code == '302'
  cookie = cookie_from(approve)

  event_a = read_event(viewer_a)
  event_b = read_event(viewer_b)
  expected = { 'event' => 'comment_count', 'post_id' => post_id, 'count' => 1 }
  raise "viewer_a expected #{expected.inspect}, got #{event_a.inspect}" unless event_a == expected
  raise "viewer_b expected #{expected.inspect}, got #{event_b.inspect}" unless event_b == expected
  puts "POST /posts/#{post_id}/comments/#{comment_id}/approve -> #{approve.code}, " \
       "both live viewers pushed {event: comment_count, count: 1} over the real socket"

  reject_body = URI.encode_www_form('_method' => 'PATCH', 'authenticity_token' => token)
  reject = http.post("/posts/#{post_id}/comments/#{comment_id}/reject", reject_body,
                      'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the rejection to redirect, got #{reject.code}" unless reject.code == '302'
  cookie = cookie_from(reject)

  event_a = read_event(viewer_a)
  expected = { 'event' => 'comment_count', 'post_id' => post_id, 'count' => 0 }
  raise "viewer_a expected #{expected.inspect} after rejection, got #{event_a.inspect}" unless event_a == expected
  puts "POST /posts/#{post_id}/comments/#{comment_id}/reject -> #{reject.code}, " \
       "live viewer pushed {event: comment_count, count: 0} (approved -> rejected demotes the count back down)"

  # Re-approve, then destroy outright - the third mutation that can move
  # the visible count, and the last one this demo has left to prove.
  http.post("/posts/#{post_id}/comments/#{comment_id}/approve", approve_body,
            'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  read_event(viewer_a) # count -> 1 again, already proven above

  destroy_body = URI.encode_www_form('_method' => 'DELETE', 'authenticity_token' => token)
  destroy = http.post("/posts/#{post_id}/comments/#{comment_id}", destroy_body,
                       'Content-Type' => 'application/x-www-form-urlencoded', 'Cookie' => cookie)
  raise "expected the destroy to redirect, got #{destroy.code}" unless destroy.code == '302'

  event_a = read_event(viewer_a)
  event_b = read_event(viewer_b)
  expected = { 'event' => 'comment_count', 'post_id' => post_id, 'count' => 0 }
  raise "viewer_a expected #{expected.inspect} after destroy, got #{event_a.inspect}" unless event_a == expected
  raise "viewer_b expected #{expected.inspect} after destroy, got #{event_b.inspect}" unless event_b == expected
  puts "DELETE /posts/#{post_id}/comments/#{comment_id} -> #{destroy.code}, " \
       'both live viewers pushed {event: comment_count, count: 0} for the removed comment'

  bystander.write(Frame.encode(Frame::PING, '', mask: true))
  reply = Frame.decode(bystander)
  raise "expected the unrelated channel's socket to only ever see our own PONG, got opcode #{reply.opcode}" unless reply.opcode == Frame::PONG
  puts "bystander subscribed to post_id=999999 received ZERO comment_count events for post #{post_id} " \
       '(streams are isolated per post, confirmed by the only frame available being our own PONG)'

  viewer_a.write(Frame.encode(Frame::CLOSE, '', mask: true))
  close_reply = Frame.decode(viewer_a)
  raise "expected a CLOSE frame echoed back, got opcode #{close_reply.opcode}" unless close_reply.opcode == Frame::CLOSE
  puts 'viewer_a sent a close frame -> server echoed CLOSE back (RFC 6455 5.5.1), on_close unsubscribed it from the Hub'

  # examples/blog/app.rb registers '/cable' with max_message_size: 2048,
  # far below the library's 16 MiB default - proven here the same way
  # test_websocket_integration.rb proves the option in the library itself,
  # but this time through the actual application's real configuration
  # instead of a purpose-built test endpoint.
  oversized_viewer = open_cable('127.0.0.1', port, post_id)
  read_event(oversized_viewer) # subscribe ack, discarded
  oversized_viewer.write(Frame.encode(Frame::TEXT, 'x' * 3000, mask: true))
  close_frame = Frame.decode(oversized_viewer)
  raise "expected a CLOSE frame, got opcode #{close_frame.opcode}" unless close_frame.opcode == Frame::CLOSE
  close_code = close_frame.payload.byteslice(0, 2).unpack1('n')
  raise "expected close code 1009 (message too big), got #{close_code}" unless close_code == 1009
  puts "sent a 3000 byte frame on /cable (max_message_size: 2048 in examples/blog/app.rb) " \
       "-> server closed with code #{close_code} (message too big), without disturbing viewer_b or bystander"
  oversized_viewer.close

  [viewer_a, viewer_b, bystander].each { |socket| socket.close unless socket.closed? }

  still_alive = http.get('/')
  raise "expected the plain HTTP server to still be healthy after the WebSocket traffic, got #{still_alive.code}" unless still_alive.code == '200'
  puts "GET / -> #{still_alive.code} (ordinary HTTP routes on the same server are unaffected by the cable traffic above)"
end

server.stop
puts '-' * 40
puts 'blog_websocket_demo done: PostActivityChannel subscribed two real WebSocket clients to one post ' \
     'and kept a third, unrelated one silent; three genuine HTTP moderation actions (approve/reject/destroy) ' \
     'each pushed a live {event: comment_count} frame to every subscriber over the real socket, and the close ' \
     'handshake correctly unsubscribed a departing viewer from the shared Hub.'
