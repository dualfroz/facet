module Facet
  module Assets
    class Manifest
      AssetNotFound = Class.new(StandardError)

      def initialize(assets = {})
        @assets = assets.transform_keys(&:to_s)
      end

      attr_reader :assets

      def []=(logical_path, fingerprinted_path)
        @assets[logical_path.to_s] = fingerprinted_path
      end

      def lookup(logical_path)
        @assets.fetch(logical_path.to_s) do
          raise AssetNotFound, "asset #{logical_path.inspect} is not in the manifest " \
                                "(known: #{@assets.keys.sort.join(', ')})"
        end
      end

      def key?(logical_path)
        @assets.key?(logical_path.to_s)
      end

      def to_h
        @assets.dup
      end

      def save(path)
        File.write(path, JSON.pretty_generate(@assets))
      end

      def self.load(path)
        return new unless File.file?(path)

        new(JSON.parse(File.read(path)))
      end
    end
  end
end
