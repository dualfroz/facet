require 'uri'
require 'json'

class PostActivityChannel
  MAX_VIEWERS_PER_POST = 500

  def self.hub
    @hub ||= Facet::WebSocket::Hub.new(max_subscribers_per_stream: MAX_VIEWERS_PER_POST)
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
  end

  def on_close(connection)
    self.class.hub.unsubscribe_all(connection)
  end

  private

  def post_id_from(connection)
    query = URI.decode_www_form(connection.env['QUERY_STRING'].to_s).to_h
    id = query['post_id'].to_s
    id.empty? ? nil : id
  end
end
