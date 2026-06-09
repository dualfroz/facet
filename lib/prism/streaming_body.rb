module Prism
  # ActionController::Live-lite: a response body whose chunks are produced
  # by the action itself, one at a time, instead of built up into a single
  # String before headers are ever sent. Response#stream wraps the given
  # block in one of these instead of the ordinary Array body, and
  # Server#write_response recognizes the type (see there) to switch the
  # wire format to HTTP/1.1 chunked Transfer-Encoding.
  #
  # Deliberately synchronous, not threaded: the block runs on the same
  # thread that iterates it (#each below), in the order it calls
  # `stream.write`. That is enough to let a large export write straight to
  # the socket as it is generated - never holding the whole payload in
  # memory at once, and letting the client start receiving bytes before the
  # last row even exists - without the complexity (and crash-on-abandoned-
  # connection risk) of ActionController::Live's separate writer thread.
  class StreamingBody
    def initialize(&producer)
      @producer = producer
    end

    # Rack's body contract: `each` is called exactly once by whatever is
    # sending the response, and yields every chunk in order. Handing the
    # producer block a Writer (instead of yielding to it directly) is what
    # lets action code say `stream.write(row)` repeatedly rather than
    # returning an Enumerable of precomputed chunks.
    def each(&sink)
      @producer.call(Writer.new(sink))
      nil
    end

    class Writer
      def initialize(sink)
        @sink = sink
      end

      def write(chunk)
        @sink.call(chunk.to_s)
        self
      end
      alias_method :<<, :write
    end
  end
end
