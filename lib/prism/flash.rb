module Prism
  class Flash
    SessionKey = '_flash'.freeze

    def initialize(session)
      @session = session
      loaded = session[SessionKey]
      @current = loaded ? Params.from(loaded) : Params.new
      @pending = Params.new
      session.delete(SessionKey)
    end

    def [](key)
      @current[key]
    end

    def []=(key, value)
      @pending[key] = value
    end

    def now
      @current
    end

    def keep(key = nil)
      if key
        @pending[key] = @current[key] if @current.key?(key)
      else
        @current.each { |name, value| @pending[name] = value }
      end
    end

    def discard(key = nil)
      key ? @current.delete(key) : @current.clear
    end

    def empty?
      @current.empty?
    end

    def to_h
      @current.to_h
    end

    def sweep
      @session.delete(SessionKey)
      @session[SessionKey] = @pending.to_h unless @pending.empty?
    end
  end
end
