module Prism
  # HTTP conditional GET support (ETag / Last-Modified), mixed into
  # Controller alongside Renderable. Requires the host to provide
  # `headers`, `request` and `halt` (all supplied by Renderable).
  module ConditionalGet
    # Sets ETag/Last-Modified and halts with 304 if the client's cached
    # copy is still fresh. Returns nil (via halt) when it short-circuits.
    def fresh_when(etag: nil, last_modified: nil, weak: true)
      set_conditional_headers(etag: etag, last_modified: last_modified, weak: weak)
      halt(412, '') if precondition_failed?
      halt(304, '') if request_fresh?
    end

    # Sets ETag/Last-Modified and returns whether the response is stale
    # (i.e. whether the caller should still render). Halts with 304 itself
    # when the client's copy is fresh, so callers can write
    # `render(...) if stale?(etag: post)`.
    def stale?(etag: nil, last_modified: nil, weak: true)
      set_conditional_headers(etag: etag, last_modified: last_modified, weak: weak)
      halt(412, '') if precondition_failed?
      fresh = request_fresh?
      halt(304, '') if fresh
      !fresh
    end

    private

    # If-Match/If-Unmodified-Since guard writes against the lost-update
    # problem: unlike If-None-Match/If-Modified-Since (which ask "may I
    # skip re-sending this?"), these ask "does the client's copy still
    # match what's on the server?" and abort the request with 412 when it
    # does not, regardless of HTTP method.
    def precondition_failed?
      match = request.headers['If-Match']
      unmodified_since = request.headers['If-Unmodified-Since']
      return false if match.nil? && unmodified_since.nil?

      match_ok = match.nil? || etag_matches?(match)
      unmodified_ok = unmodified_since.nil? || not_modified_since?(unmodified_since)
      !(match_ok && unmodified_ok)
    end

    def set_conditional_headers(etag:, last_modified:, weak:)
      if etag
        digest = Digest::SHA1.hexdigest(etag.to_s)
        headers['ETag'] = weak ? %(W/"#{digest}") : %("#{digest}")
      end
      headers['Last-Modified'] = last_modified.utc.httpdate if last_modified
    end

    def request_fresh?
      none_match = request.headers['If-None-Match']
      modified_since = request.headers['If-Modified-Since']
      return false if none_match.nil? && modified_since.nil?

      etag_fresh = none_match.nil? || etag_matches?(none_match)
      time_fresh = modified_since.nil? || not_modified_since?(modified_since)
      etag_fresh && time_fresh
    end

    def etag_matches?(header_value)
      current = headers['ETag']
      return false unless current
      header_value.split(',').map(&:strip).any? { |candidate| candidate == '*' || candidate == current }
    end

    def not_modified_since?(header_value)
      current = headers['Last-Modified']
      return false unless current
      Time.httpdate(header_value) >= Time.httpdate(current)
    rescue ArgumentError
      false
    end
  end
end
