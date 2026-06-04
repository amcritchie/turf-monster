# DB-backed magic link (overrides the stateless signed-token service that
# studio-engine ships — the host app's autoload path wins for the `MagicLink`
# constant, so this class replaces it app-wide).
#
# WHY DB-backed: the signed self-contained token was ~330 URL chars (email +
# return_to + jti + a `_rails` expiry envelope, double-base64'd). Storing the
# payload here and putting only a short random key in the link gets the URL down
# to ~16 chars, keeps the email/return_to off the wire entirely, and makes
# single-use a column flip — no Redis, so it also can't be broken by a misset
# cache (the prod redis-TLS lockout footgun).
#
# API preserved for MagicLinksController + test helpers:
#   MagicLink.generate(email:, return_to: nil) -> token String
#   MagicLink.consume(token)                   -> Result(email, return_to)  (raises InvalidToken)
#   MagicLink::InvalidToken, MagicLink::TTL
class MagicLink < ApplicationRecord
  TTL = 15.minutes

  class InvalidToken < StandardError; end

  Result = Struct.new(:email, :return_to, keyword_init: true)

  class << self
    # Creates a single-use link row and returns its opaque URL token. The token
    # is URL-safe base64 (no "/", "+", "="), so it satisfies the %r{[^/]+} route
    # constraint and survives URL generation without extra encoding.
    def generate(email:, return_to: nil)
      email      = normalize_email(email)
      return_to  = sanitize_path(return_to)
      # 96 bits of randomness — collision is astronomically unlikely, but retry a
      # few times on the off chance the unique index rejects a dupe. The final
      # attempt is outside the rescue so a persistent failure raises cleanly
      # rather than returning a nil row.
      2.times do
        return create!(token: SecureRandom.urlsafe_base64(12), email: email,
                       return_to: return_to, expires_at: TTL.from_now).token
      rescue ActiveRecord::RecordNotUnique
        next
      end
      create!(token: SecureRandom.urlsafe_base64(12), email: email,
              return_to: return_to, expires_at: TTL.from_now).token
    end

    # Authoritative consume: validates existence + not-expired + not-yet-used,
    # then atomically burns it (only the first caller flips consumed_at, so a
    # replay / double-submit loses the race and is rejected).
    def consume(token)
      link = find_by(token: token.to_s)
      raise InvalidToken, "unknown link" unless link

      burned = where(id: link.id, consumed_at: nil)
               .where("expires_at > ?", Time.current)
               .update_all(consumed_at: Time.current)
      raise InvalidToken, "link already used or expired" if burned.zero?

      Result.new(email: link.email, return_to: sanitize_path(link.return_to))
    end

    private

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    # Only same-origin absolute paths survive; protocol-relative ("//evil"),
    # absolute URLs, and relative paths collapse to nil so callers fall back to a
    # default redirect. Mirrors the engine service's sanitizer.
    def sanitize_path(path)
      p = path.to_s
      p.start_with?("/") && !p.start_with?("//") ? p : nil
    end
  end
end
