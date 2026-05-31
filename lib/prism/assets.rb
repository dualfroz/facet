require_relative 'assets/manifest'
require_relative 'assets/compiler'

module Prism
  # Sprockets/Propshaft-lite static asset pipeline: Compiler fingerprints
  # files on disk into a Manifest, Application#enable_assets makes that
  # manifest available app-wide so Assets::Helpers (asset_path and friends)
  # can look logical paths up in it, and Middleware::Assets serves the
  # fingerprinted files back out with a far-future Cache-Control header
  # (safe because the filename changes whenever the content does).
  module Assets
    class << self
      attr_writer :manifest

      def manifest
        @manifest
      end

      def enabled?
        !@manifest.nil?
      end

      def reset!
        @manifest = nil
      end
    end
  end
end
