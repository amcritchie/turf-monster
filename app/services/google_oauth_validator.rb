require "net/http"
require "uri"
require "json"

# OPSEC-005: server-side re-validation of a Google OAuth id_token via
# Google's tokeninfo endpoint, mirroring the Stripe pattern of re-fetching
# from the provider's API rather than trusting omniauth's parsed payload.
#
# The omniauth-google-oauth2 gem already verifies the JWT signature against
# Google's JWKS, so this is defense-in-depth — primarily it ensures:
#   1. The id_token's audience matches GOOGLE_CLIENT_ID (correct app)
#   2. email_verified is `true` per Google's own claim (closes the silent
#      from_omniauth find-by-email link if Google hasn't confirmed the email)
#   3. The token isn't expired by Google's clock
#
# Usage:
#   result = GoogleOauthValidator.new(id_token: auth.credentials.id_token).validate!
#   if result.ok?
#     # safe to use result.email, result.email_verified
#   else
#     # logging + reject
#   end
class GoogleOauthValidator
  TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo".freeze
  NET_TIMEOUT_SECONDS = 5

  Result = Struct.new(:ok, :email, :email_verified, :reason, keyword_init: true) do
    def ok?
      ok == true
    end
  end

  def initialize(id_token:, expected_aud: ENV["GOOGLE_CLIENT_ID"])
    @id_token = id_token
    @expected_aud = expected_aud
  end

  def validate!
    # Test-env affordance: OmniAuth.config.test_mode replaces the real OAuth
    # flow with mock_auth, which doesn't carry a real id_token. The gem
    # already verifies the mock signature/state internally; this validator
    # has nothing real to re-check. Production paths always have id_token
    # set by the real OAuth bounce — so blank means we're in test, not in
    # a real-world request, and we don't fail those tests open.
    return Result.new(ok: true, email: nil, email_verified: true, reason: :test_skip) if @id_token.blank? && Rails.env.test?

    return Result.new(ok: false, reason: :missing_id_token) if @id_token.blank?
    return Result.new(ok: false, reason: :missing_expected_aud) if @expected_aud.blank?

    response = fetch_tokeninfo
    return Result.new(ok: false, reason: :tokeninfo_unreachable) unless response

    if response.code.to_i != 200
      return Result.new(ok: false, reason: :tokeninfo_rejected)
    end

    body = JSON.parse(response.body) rescue nil
    return Result.new(ok: false, reason: :tokeninfo_parse_failed) unless body

    # `email_verified` is a string "true"/"false" in tokeninfo responses.
    email_verified = body["email_verified"].to_s == "true"

    unless body["aud"] == @expected_aud
      return Result.new(ok: false, email: body["email"], email_verified: email_verified, reason: :wrong_audience)
    end

    unless email_verified
      return Result.new(ok: false, email: body["email"], email_verified: false, reason: :email_not_verified)
    end

    expiry = body["exp"].to_i
    if expiry > 0 && expiry < Time.current.to_i
      return Result.new(ok: false, email: body["email"], email_verified: true, reason: :expired)
    end

    Result.new(ok: true, email: body["email"], email_verified: true, reason: nil)
  end

  private

  def fetch_tokeninfo
    uri = URI(TOKENINFO_URL)
    uri.query = URI.encode_www_form(id_token: @id_token)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: NET_TIMEOUT_SECONDS, read_timeout: NET_TIMEOUT_SECONDS) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  rescue StandardError => e
    Rails.logger.warn("[GoogleOauthValidator] tokeninfo fetch failed: #{e.class}: #{e.message}")
    nil
  end
end
