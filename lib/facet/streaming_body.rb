module Facet
  class StreamingBody
    def initialize(&producer)
      @producer = producer
    end

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
