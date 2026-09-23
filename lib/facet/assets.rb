require_relative 'assets/manifest'
require_relative 'assets/compiler'

module Facet
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
