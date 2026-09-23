module Facet
  class Params < Hash
    def self.from(source)
      source.each_with_object(new) { |(key, value), acc| acc[key] = value }
    end

    def self.nested_from(pairs)
      pairs.each_with_object(new) { |(key, value), acc| assign_pair(acc, key, value) }
    end

    def self.assign_pair(container, key, value)
      segments = key.to_s.scan(/[^\[\]]+|\[\]/)
      name = segments.shift
      return if name.nil?
      insert(container, name, segments, value)
    end

    def self.insert(container, key, remaining, value)
      if remaining.empty?
        container[key] = value
      elsif remaining.first == '[]'
        (container[key] ||= []) << value
      else
        container[key] ||= new
        insert(container[key], remaining.shift, remaining, value)
      end
    end
    private_class_method :insert

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

    def delete(key, &block)
      super(convert_key(key), &block)
    end

    private

    def convert_key(key)
      key.is_a?(Symbol) ? key.to_s : key
    end
  end
end
