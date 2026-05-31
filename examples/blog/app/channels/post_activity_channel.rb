require 'uri'
require 'json'

# ActionCable-lite channel for posts#show: anyone with a post open can
# subscribe (GET /cable?post_id=N, upgraded to a WebSocket) to hear about
# moderation events on that post's comments - approved, rejected, or
# removed - the instant they happen, instead of polling or reloading.
# CommentsController broadcasts through the same Hub every time one of
# those three actions changes the post's *visible* (approved) comment
# count; this channel itself never accepts anything back from the client,
# it only ever pushes.
class PostActivityChannel
  # A hard cap on live viewers per post - without one, one post going viral
  # would mean one Hub#broadcast call fanning out to an unbounded number of
  # live sockets on every single moderation action. Real, but generous
  # enough that the demo's handful of viewers never trips it by accident.
  MAX_VIEWERS_PER_POST = 500

  def self.hub
    @hub ||= Prism::WebSocket::Hub.new(max_subscribers_per_stream: MAX_VIEWERS_PER_POST)
  end

  def self.stream_for(post_id)
    "post_#{post_id}_comments"
  end

  def on_open(connection)
    post_id = post_id_from(connection)
    return connection.close(1008, 'post_id query parameter is required') unless post_id
    unless self.class.hub.subscribe(self.class.stream_for(post_id), connection)
      return connection.close(1008, 'this post already has the maximum number of live viewers')
    end
    connection.write_text(JSON.generate(event: 'subscribed', post_id: post_id))
  end

  def on_message(connection, _message)
    # Read-only stream - nothing a client sends is ever acted on.
  end

  def on_close(connection)
    self.class.hub.unsubscribe_all(connection)
  end

  private

  # The handshake request never reaches a Prism::Request/Params, just the
  # raw Rack env the server captured before the Upgrade (see
  # Prism::Server#handle_websocket) - so the query string is decoded by
  # hand here instead of through Prism::Params#nested_from, which only
  # ever runs as part of an ordinary Request#params call.
  def post_id_from(connection)
    query = URI.decode_www_form(connection.env['QUERY_STRING'].to_s).to_h
    id = query['post_id'].to_s
    id.empty? ? nil : id
  end
end
