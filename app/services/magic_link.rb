# Unified create-or-login magic link.
#
# A magic link is a signed, short-lived, single-use token keyed on an EMAIL
# (the user may not exist yet — clicking the link either logs them in or
# creates the account). The token is a `message_verifier("magic_link_v1")`
# payload carrying the email + a sanitized return_to + a random jti.
#
# Single-use is enforced with the jti: on `generate` we record the jti in
# Rails.cache (Redis, cross-process); on `consume` we delete it and reject if
# it was already gone (replay / second click). The signature already covers
# tamper + expiry; the jti closes the replay gap the email_verification token
# (which this mirrors) intentionally left open.
#
# NOTE on test env: the test cache is :null_store, where writes/deletes are
# no-ops and `delete` always returns false — enforcing single-use there would
# reject every legitimate consume. So enforcement is skipped for non-tracking
# stores; the service unit test injects a real MemoryStore to exercise it.
class MagicLink
  TOKEN_KEY = "magic_link_v1"
  TTL       = 15.minutes
  JTI_TTL   = 20.minutes # outlive the token so a valid token's jti is always present

  class InvalidToken < StandardError; end

  Result = Struct.new(:email, :return_to, keyword_init: true)

  class << self
    # Test seam — defaults to Rails.cache. The service unit test sets this to
    # an ActiveSupport::Cache::MemoryStore to assert single-use, then resets it.
    attr_writer :cache

    def cache
      @cache || Rails.cache
    end

    # Returns a signed token string. `return_to` is sanitized to a local path.
    # The MessageVerifier blob is standard base64 (can contain "/" and "+"),
    # which breaks the `%r{[^/]+}` route constraint once the payload is large
    # enough to emit a "/" (e.g. a return_to carrying a contest path). Wrap it
    # URL-safe so the token is always [A-Za-z0-9_-]=, matching the route and
    # surviving URL generation.
    def generate(email:, return_to: nil)
      normalized = normalize_email(email)
      jti = SecureRandom.hex(16)
      cache.write(jti_key(jti), normalized, expires_in: JTI_TTL) if enforce_single_use?
      raw = verifier.generate(
        { email: normalized, return_to: sanitize_path(return_to), jti: jti, v: 1 },
        expires_in: TTL
      )
      Base64.urlsafe_encode64(raw)
    end

    # Verifies signature + expiry + single-use. Returns a Result or raises
    # InvalidToken. Idempotency is NOT offered — a consumed token is dead.
    def consume(token)
      raw = Base64.urlsafe_decode64(token.to_s)
      payload = verifier.verify(raw).with_indifferent_access
      raise InvalidToken, "unexpected token shape" unless payload[:v] == 1 && payload[:email].present?

      if enforce_single_use?
        # delete returns true only when the jti was still present
        raise InvalidToken, "link already used or expired" unless cache.delete(jti_key(payload[:jti]))
      elsif !Rails.env.test?
        # Single-use is disabled (non-tracking cache). Expected in :null_store
        # dev; in any other env it means replay protection is silently OFF —
        # tokens are replayable for their TTL. Surface it loudly.
        Rails.logger.warn("[MagicLink] single-use NOT enforced (cache=#{cache.class}); links are replayable until expiry")
      end

      Result.new(email: payload[:email], return_to: sanitize_path(payload[:return_to]))
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      # ArgumentError → malformed base64 (tampered/truncated token).
      raise InvalidToken, "invalid or expired link"
    end

    private

    def verifier
      Rails.application.message_verifier(TOKEN_KEY)
    end

    def jti_key(jti)
      "magic_link/jti/#{jti}"
    end

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    # Only same-origin absolute paths survive; everything else (protocol-relative
    # "//evil", absolute URLs, blank) collapses to nil so callers fall back to a
    # default redirect.
    def sanitize_path(path)
      p = path.to_s
      p.start_with?("/") && !p.start_with?("//") ? p : nil
    end

    def enforce_single_use?
      !cache.is_a?(ActiveSupport::Cache::NullStore)
    end
  end
end
