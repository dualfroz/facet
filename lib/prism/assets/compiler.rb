require 'fileutils'

module Prism
  module Assets
    # Sprockets/Propshaft-lite precompile step: walks every file under
    # `source`, content-addresses it (sha256, first 8 hex chars) into
    # `name-digest.ext` under `output`, and writes a manifest.json mapping
    # the original relative path ("css/application.css") to the
    # fingerprinted one ("css/application-3f2a9c1e.css"). Re-running with
    # unchanged file content reproduces the exact same fingerprinted name
    # (pure function of the bytes, no timestamps involved), and any
    # fingerprinted file left over from a PREVIOUS compile that no logical
    # path points to anymore is deleted - the same cleanup
    # `rake assets:clean` does in Rails, done automatically on every compile
    # instead of as a separate step.
    class Compiler
      DIGEST_LENGTH = 8

      def initialize(source:, output:)
        @source = File.expand_path(source)
        @output = File.expand_path(output)
      end

      def compile!
        FileUtils.mkdir_p(@output)
        previous = Manifest.load(manifest_path).to_h.values
        manifest = Manifest.new

        each_source_file do |absolute, logical_path|
          fingerprinted = fingerprint(logical_path, absolute)
          destination = File.join(@output, fingerprinted)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(absolute, destination)
          manifest[logical_path] = fingerprinted
        end

        stale = previous - manifest.to_h.values
        stale.each { |path| FileUtils.rm_f(File.join(@output, path)) }

        manifest.save(manifest_path)
        manifest
      end

      def manifest_path
        File.join(@output, 'manifest.json')
      end

      private

      def each_source_file
        return unless File.directory?(@source)

        Dir.glob(File.join(@source, '**', '*')).sort.each do |absolute|
          next unless File.file?(absolute)

          yield absolute, absolute.delete_prefix("#{@source}/")
        end
      end

      def fingerprint(logical_path, absolute)
        digest = Digest::SHA256.file(absolute).hexdigest[0, DIGEST_LENGTH]
        ext = File.extname(logical_path)
        base = logical_path.delete_suffix(ext)
        "#{base}-#{digest}#{ext}"
      end
    end
  end
end
