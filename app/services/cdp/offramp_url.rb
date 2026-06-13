module Cdp
  # Builds the Coinbase-hosted OFFRAMP (sell / cash-out) widget URL.
  # See docs/CDP_RAMP_INTEGRATION.md §7.
  #
  # sessionToken, partnerUserRef (<50 chars), and redirectUrl are ALL required
  # for offramp (unlike onramp where only sessionToken is documented required —
  # we enforce all three on both for correlation anyway).
  module OfframpUrl
    BASE = "https://pay.coinbase.com/v3/sell/input".freeze

    CASHOUT_METHODS = %w[FIAT_WALLET CRYPTO_ACCOUNT ACH_BANK_ACCOUNT PAYPAL].freeze

    OPTIONAL_PARAMS = {
      preset_crypto_amount:   "presetCryptoAmount",
      preset_fiat_amount:     "presetFiatAmount",
      default_cashout_method: "defaultCashoutMethod",
      fiat_currency:          "fiatCurrency",
      disable_edit:           "disableEdit"
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
      # presetCryptoAmount XOR presetFiatAmount — the offramp widget takes one.
      if options[:preset_crypto_amount].present? && options[:preset_fiat_amount].present?
        raise ArgumentError, "presetCryptoAmount and presetFiatAmount are mutually exclusive"
      end
      if options[:default_cashout_method].present? && !CASHOUT_METHODS.include?(options[:default_cashout_method].to_s)
        raise ArgumentError, "defaultCashoutMethod must be one of #{CASHOUT_METHODS.join(', ')}"
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
        param = OPTIONAL_PARAMS[key] or raise ArgumentError, "unknown offramp param: #{key}"
        params[param] = value
      end

      "#{BASE}?#{URI.encode_www_form(params)}"
    end
  end
end
