require 'tempfile'

module Facet
  class UploadedFile
    attr_reader :original_filename, :content_type, :tempfile

    def initialize(original_filename:, content_type:, tempfile:)
      @original_filename = original_filename
      @content_type = content_type
      @tempfile = tempfile
    end

    def path
      tempfile.path
    end

    def size
      tempfile.size
    end

    def read(*args)
      tempfile.read(*args)
    end

    def rewind
      tempfile.rewind
    end

    def to_s
      original_filename.to_s
    end
  end

  module Multipart
    MalformedError = Class.new(StandardError)

    CONTENT_TYPE_RE = %r{\Amultipart/form-data}i.freeze

    module_function

    def multipart?(content_type)
      !content_type.nil? && CONTENT_TYPE_RE.match?(content_type)
    end

    def boundary_from(content_type)
      return nil unless content_type
      match = content_type.match(/boundary=(?:"([^"]*)"|([^;\s]+))/i)
      return nil unless match
      match[1] || match[2]
    end

    def parse(body, boundary)
      return Facet::Params.new if boundary.nil? || boundary.empty? || body.nil?

      body = body.dup.force_encoding(Encoding::BINARY)
      delimiter = "--#{boundary}"
      pieces = body.split(delimiter)
      pairs = pieces[1..-2].to_a.filter_map do |piece|
        part = piece.sub(/\A\r\n/, '').sub(/\r\n\z/, '')
        part.empty? ? nil : part_pair(part)
      end.compact
      Facet::Params.nested_from(pairs)
    end

    def part_pair(part)
      header_block, separator, content = part.partition("\r\n\r\n")
      return nil if separator.empty?

      headers = parse_headers(header_block)
      disposition = headers['content-disposition']
      return nil unless disposition

      name = extract_token(disposition, 'name')
      return nil unless name

      filename = extract_token(disposition, 'filename')
      value =
        if filename
          build_uploaded_file(filename, headers['content-type'], content)
        else
          content.dup.force_encoding(Encoding::UTF_8)
        end

      [name, value]
    end

    def build_uploaded_file(filename, content_type, content)
      tempfile = Tempfile.new('facet-upload')
      tempfile.binmode
      tempfile.write(content)
      tempfile.rewind
      UploadedFile.new(original_filename: filename, content_type: content_type, tempfile: tempfile)
    end

    def parse_headers(block)
      block.split("\r\n").each_with_object({}) do |line, acc|
        key, value = line.split(':', 2)
        next unless key && value
        acc[key.strip.downcase] = value.strip
      end
    end

    def extract_token(header_value, key)
      match = header_value.match(/#{key}="([^"]*)"/) || header_value.match(/#{key}=([^;\s]+)/)
      match && match[1]
    end
  end
end
