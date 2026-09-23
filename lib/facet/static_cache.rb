module Facet
  module StaticCache
    def self.weak_validators(size, mtime)
      etag = %(W/"#{size}-#{mtime.to_i}")
      [etag, mtime.utc.httpdate]
    end

    def self.strong_etag(fingerprint_hash)
      %("#{fingerprint_hash}")
    end

    def self.not_modified?(env, etag, last_modified)
      none_match = env['HTTP_IF_NONE_MATCH']
      modified_since = env['HTTP_IF_MODIFIED_SINCE']
      return false if none_match.nil? && modified_since.nil?

      etag_fresh = none_match.nil? || etag_matches?(none_match, etag)
      time_fresh = modified_since.nil? || not_newer_than?(modified_since, last_modified)
      etag_fresh && time_fresh
    end

    def self.range_applicable?(env, etag, last_modified)
      if_range = env['HTTP_IF_RANGE']
      return true if if_range.nil?

      if entity_tag?(if_range)
        strong_etag_match?(if_range, etag)
      else
        exact_date_match?(if_range, last_modified)
      end
    end

    def self.entity_tag?(value)
      value.start_with?('"') || value.start_with?('W/"')
    end
    private_class_method :entity_tag?

    def self.strong_etag_match?(header_value, current_etag)
      return false if current_etag.nil? || current_etag.start_with?('W/')
      return false if header_value.start_with?('W/')

      header_value == current_etag
    end
    private_class_method :strong_etag_match?

    def self.exact_date_match?(header_value, last_modified_header)
      return false if last_modified_header.nil?

      Time.httpdate(header_value) == Time.httpdate(last_modified_header)
    rescue ArgumentError
      false
    end
    private_class_method :exact_date_match?

    def self.etag_matches?(header_value, current_etag)
      return false if current_etag.nil?

      header_value.split(',').map(&:strip).any? { |candidate| candidate == '*' || candidate == current_etag }
    end
    private_class_method :etag_matches?

    def self.not_newer_than?(header_value, current_last_modified)
      return false if current_last_modified.nil?

      Time.httpdate(header_value) >= Time.httpdate(current_last_modified)
    rescue ArgumentError
      false
    end
    private_class_method :not_newer_than?
  end
end
