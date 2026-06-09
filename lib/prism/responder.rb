module Prism
  # Collects per-format render blocks for Controller#respond_to, mirroring
  # Rails' `respond_to { |format| format.html { ... }; format.json { ... } }`.
  class Responder
    class UnknownFormat < StandardError; end

    def initialize
      @blocks = {}
    end

    def method_missing(name, &block)
      return super unless block
      @blocks[name.to_sym] = block
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    # Registers a fallback block for any format not already handled.
    # `any` (no args) applies to every format that gets a respond() call
    # later; `any(:json, :xml)` restricts the fallback to those formats.
    def any(*formats, &block)
      if formats.empty?
        @fallback = block
      else
        formats.each { |format| @blocks[format.to_sym] ||= block }
      end
    end

    def handles?(format)
      @blocks.key?(format.to_sym) || !@fallback.nil?
    end

    def respond(format)
      handler = @blocks[format.to_sym] || @fallback
      raise UnknownFormat, "no handler registered for format #{format.inspect}" unless handler
      handler.call
    end
  end
end
