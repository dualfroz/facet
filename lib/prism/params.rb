module Prism
  class Params < Hash
    def self.from(source)
      source.each_with_object(new) { |(key, value), acc| acc[key] = value }
    end

    def [](key)
      super(convert_key(key))
    end

    def []=(key, value)
      super(convert_key(key), value)
    end

    def fetch(key, *rest, &block)
      super(convert_key(key), *rest, &block)
    end

    def dig(key, *rest)
      super(convert_key(key), *rest)
    end

    def key?(key)
      super(convert_key(key))
    end
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    private

    def convert_key(key)
      key.is_a?(Symbol) ? key.to_s : key
    end
  end
end
