module Prism
  module Assets
    # Maps logical asset paths ("application.css") to fingerprinted paths
    # ("application-3f2a9c1e.css") the way Sprockets/Propshaft's
    # manifest.json does. Purely a lookup table plus JSON (de)serialization -
    # Compiler is what actually populates one.
    class Manifest
      AssetNotFound = Class.new(StandardError)

      def initialize(assets = {})
        @assets = assets.transform_keys(&:to_s)
      end

      attr_reader :assets

      def []=(logical_path, fingerprinted_path)
        @assets[logical_path.to_s] = fingerprinted_path
      end

      # Raises when the manifest is authoritative (production-style,
      # precompiled ahead of time) so a typo in a view never silently links
      # to a 404 - the same tradeoff Rails makes with
      # config.assets.unknown_asset_fallback = false.
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
