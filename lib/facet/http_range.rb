module Facet
  module HttpRange
    Satisfiable = Struct.new(:start, :finish, :length, keyword_init: true)

    SPEC = /\A(\d*)-(\d*)\z/.freeze

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

    def self.read_slice(path, satisfiable)
      File.open(path, 'rb') do |f|
        f.seek(satisfiable.start)
        f.read(satisfiable.length) || String.new
      end
    end
  end
end
