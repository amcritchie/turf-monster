module Cdp
  # Builds the Coinbase-hosted ONRAMP (buy) widget URL.
  # See docs/CDP_RAMP_INTEGRATION.md §6. Documented params only.
  #
  # NB: the param is partnerUserRef, NOT partnerUserId (the sell-quote API uses
  # partnerUserId — a different param on a different API; mixing them silently
  # breaks status correlation).
  module OnrampUrl
    BASE = "https://pay.coinbase.com/buy/select-asset".freeze

    # presetFiatAmount is USD/CAD/GBP/EUR only and ignored when
    # presetCryptoAmount is set (documented behavior; both are allowed here).
    OPTIONAL_PARAMS = {
      preset_fiat_amount:     "presetFiatAmount",
      preset_crypto_amount:   "presetCryptoAmount",
      default_experience:     "defaultExperience", # "buy" | "send"
      default_payment_method: "defaultPaymentMethod",
      fiat_currency:          "fiatCurrency",
      handling_requested_urls: "handlingRequestedUrls"
    }.freeze

    module_function

    def build(session_token:, partner_user_ref:, redirect_url:,
              default_network: "solana", default_asset: "USDC", **options)
      raise ArgumentError, "session_token is required" if session_token.blank?
      raise ArgumentError, "partner_user_ref is required" if partner_user_ref.blank?
      raise ArgumentError, "redirect_url is required" if redirect_url.blank?
      if partner_user_ref.to_s.length > CdpRampTransaction::PARTNER_USER_REF_MAX
        raise ArgumentError, "partner_user_ref must be < 50 chars (got #{partner_user_ref.to_s.length})"
      end

      params = {
        "sessionToken"   => session_token,
        "partnerUserRef" => partner_user_ref,
        "redirectUrl"    => redirect_url,
        "defaultNetwork" => default_network,
        "defaultAsset"   => default_asset
      }
      options.each do |key, value|
        next if value.nil?
        param = OPTIONAL_PARAMS[key] or raise ArgumentError, "unknown onramp param: #{key}"
        params[param] = value
      end

      "#{BASE}?#{URI.encode_www_form(params)}"
    end
  end
end
