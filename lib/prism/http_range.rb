module Prism
  # RFC 7233 single-range parsing, shared by Middleware::Static and
  # Middleware::Assets so both can serve `Range: bytes=...` requests (video
  # seeking, resumable downloads, `curl -C -`) instead of always sending the
  # whole file. Only a single byte-range-spec is honored - a request naming
  # several comma-separated ranges falls back to a normal 200 with the full
  # body, which RFC 7233 SS3.1 explicitly allows ("MAY ignore the Range
  # header field"), rather than implementing multipart/byteranges for a case
  # none of this framework's own clients ever send.
  module HttpRange
    Satisfiable = Struct.new(:start, :finish, :length, keyword_init: true)

    SPEC = /\A(\d*)-(\d*)\z/.freeze

    # Returns:
    #   nil            - no Range header, or one this server chooses to ignore
    #                     (multi-range) -> caller should send a normal 200.
    #   :unsatisfiable - a single range was given but it names no byte that
    #                     exists in a file of `file_size` bytes -> caller
    #                     should send 416.
    #   Satisfiable     - a single, in-bounds range -> caller should send 206.
    def self.parse(header, file_size)
      return nil if header.nil? || !header.start_with?('bytes=')

      specs = header.delete_prefix('bytes=').split(',', -1).map(&:strip)
      return nil if specs.size != 1

      match = SPEC.match(specs.first)
      return :unsatisfiable unless match

      start_s, end_s = match[1], match[2]
      return :unsatisfiable if start_s.empty? && end_s.empty?

      if start_s.empty?
        suffix_length = end_s.to_i
        return :unsatisfiable if suffix_length <= 0
        start = [file_size - suffix_length, 0].max
        finish = file_size - 1
      else
        start = start_s.to_i
        finish = end_s.empty? ? file_size - 1 : [end_s.to_i, file_size - 1].min
      end

      return :unsatisfiable if file_size.zero? || start >= file_size || start > finish

      Satisfiable.new(start: start, finish: finish, length: finish - start + 1)
    end

    # Reads only the requested slice, without loading the rest of the file
    # into memory - the entire point of Range for a large video/asset file.
    def self.read_slice(path, satisfiable)
      File.open(path, 'rb') do |f|
        f.seek(satisfiable.start)
        f.read(satisfiable.length) || String.new
      end
    end
  end
end
