# EdDSA support was extracted out of jwt 3.x into the jwt-eddsa gem — without
# this require, JWT.encode(..., "EdDSA") raises "Unsupported signing method".
require "jwt/eddsa"

module Cdp
  # Mints the per-request Bearer JWT for Coinbase CDP REST calls
  # (docs.cdp.coinbase.com JWT auth, verified recipe — see
  # docs/CDP_RAMP_INTEGRATION.md §3).
  #
  # The `uri` claim binds each token to exactly ONE method+host+path
  # ("POST api.developer.coinbase.com/onramp/v1/token" — no scheme, no space
  # between host and path) and tokens live 120 seconds, so a FRESH JWT must be
  # generated per request — never cache one.
  class Auth
    HOST = "api.developer.coinbase.com".freeze
    TTL_SECONDS = 120 # 2-minute max validity per CDP docs

    # CDP_API_KEY_SECRET misconfiguration (wrong key type, truncated paste).
    class ConfigError < StandardError; end

    # Returns an EdDSA-signed JWT bound to `method` + `path`, e.g.
    #   Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token")
    def self.jwt_for(method:, path:)
      new.jwt_for(method: method, path: path)
    end

    def jwt_for(method:, path:)
      now = Time.now.to_i
      header = {
        alg: "EdDSA",
        typ: "JWT",
        kid: key_id,
        nonce: SecureRandom.hex(16)
      }
      claims = {
        sub: key_id,
        iss: "cdp",
        aud: ["cdp_service"],
        nbf: now,
        exp: now + TTL_SECONDS,
        uri: "#{method.to_s.upcase} #{HOST}#{path}"
      }
      JWT.encode(claims, signing_key, "EdDSA", header)
    end

    private

    def key_id
      ENV.fetch("CDP_API_KEY_ID")
    end

    # CDP_API_KEY_SECRET is base64 and MUST decode to exactly 64 bytes:
    # 32-byte Ed25519 seed followed by the 32-byte public key. Anything else
    # means the wrong key type (e.g. an ECDSA key) or a truncated paste.
    def signing_key
      decoded = Base64.decode64(ENV.fetch("CDP_API_KEY_SECRET"))
      if decoded.length != 64
        raise ConfigError,
              "Invalid Ed25519 key length: CDP_API_KEY_SECRET must decode to 64 bytes (got #{decoded.length})"
      end
      Ed25519::SigningKey.new(decoded[0, 32])
    end
  end
end
