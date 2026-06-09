module Prism
  # Conditional-GET (ETag/Last-Modified/304) and If-Range validation for
  # Middleware::Static/Assets. Kept separate from Prism::ConditionalGet
  # (which is mixed into Controller and reads/writes headers through
  # `request`/`headers`/`halt`) because the static-file middleware works
  # directly on a Rack env and a plain headers Hash, with no controller
  # instance to hang state off of.
  module StaticCache
    # Cheap validators for an arbitrary file: a weak ETag derived from size
    # and mtime (no content read - the whole point for large files) plus a
    # Last-Modified date. Weak because two files can share size+mtime
    # without being byte-identical, so this can only ever be used for
    # If-None-Match/If-Modified-Since (which allow weak comparison), never
    # for If-Range (which requires a strong validator - see range_applicable?).
    def self.weak_validators(size, mtime)
      etag = %(W/"#{size}-#{mtime.to_i}")
      [etag, mtime.utc.httpdate]
    end

    # A strong ETag for a fingerprinted asset: the content hash is already
    # in the filename (Assets::Compiler put it there), so unlike an
    # arbitrary static file we get a real content-derived validator for
    # free - no need to hash the file again just to answer If-Range.
    def self.strong_etag(fingerprint_hash)
      %("#{fingerprint_hash}")
    end

    # True when the client's cached copy is still fresh per
    # If-None-Match/If-Modified-Since - caller should respond 304.
    def self.not_modified?(env, etag, last_modified)
      none_match = env['HTTP_IF_NONE_MATCH']
      modified_since = env['HTTP_IF_MODIFIED_SINCE']
      return false if none_match.nil? && modified_since.nil?

      etag_fresh = none_match.nil? || etag_matches?(none_match, etag)
      time_fresh = modified_since.nil? || not_newer_than?(modified_since, last_modified)
      etag_fresh && time_fresh
    end

    # RFC 7233 SS3.2: If-Range names exactly one validator (an entity-tag or
    # an HTTP-date, never both/neither/a list). When present, a Range
    # request is only honored if that validator strong-matches the
    # resource's *current* state; otherwise the Range header is ignored and
    # the full body is sent - this is what lets a client resume a download
    # safely (it re-requests the whole file the moment the file changes
    # instead of stitching a byte range from the old version onto one from
    # the new). Absent If-Range, Range is always honored (existing behavior).
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

    # Strong comparison (RFC 7232 SS2.3.2): both sides must be non-weak and
    # byte-identical. Our own weak validators (plain static files) can
    # therefore never satisfy an If-Range by entity-tag - only a fingerprinted
    # asset's strong etag can, and only when the client's tag is not itself
    # marked weak.
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
