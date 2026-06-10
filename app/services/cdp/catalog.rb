module Cdp
  # Country/state + payment-method catalog for the CDP ramp — answers "can this
  # viewer Buy / Cash out USDC-on-Solana right now?" so controllers/views can
  # gate the buttons. See docs/CDP_RAMP_INTEGRATION.md §13.
  #
  # Caching: Rails.cache.fetch (12h, per the docs' "call periodically and cache")
  # PLUS per-instance @memo memoization — dev's :null_store makes Rails.cache a
  # no-op, so the @ivar layer is what keeps a single request from refetching
  # (house pattern; build one Catalog per request).
  #
  # Defensive parsing (spec open question 8): responses may or may not nest
  # under a "data" key, and the Solana network slug may be "solana" or a
  # "solana-mainnet"-style string — unwrap + fuzzy-match both.
  #
  # Availability checks FAIL CLOSED: a CDP API error logs (ErrorLog + the
  # outbound audit row from Cdp::Client) and returns false — a Coinbase outage
  # hides the buttons, it never 500s the page.
  class Catalog
    CACHE_TTL = 12.hours

    def initialize(client: Cdp::Client.new)
      @client = client
      @memo = {}
    end

    # ── Raw catalog endpoints (cached) ──────────────────────────────────────

    def buy_config
      fetch("buy_config") { @client.get("/onramp/v1/buy/config") }
    end

    def sell_config
      fetch("sell_config") { @client.get("/onramp/v1/sell/config") }
    end

    # subdivision is REQUIRED by the API when country=US (state-specific asset
    # restrictions, e.g. NY).
    def buy_options(country:, subdivision: nil)
      fetch(options_key("buy_options", country, subdivision)) do
        @client.get("/onramp/v1/buy/options", options_params(country, subdivision))
      end
    end

    def sell_options(country:, subdivision: nil)
      fetch(options_key("sell_options", country, subdivision)) do
        @client.get("/onramp/v1/sell/options", options_params(country, subdivision))
      end
    end

    # ── Availability checks (what controllers/views call) ───────────────────

    # Can this country (+ US state) buy USDC on Solana?
    def onramp_available?(country:, subdivision: nil)
      available?(direction: :buy, country: country, subdivision: subdivision)
    end

    # Can this country (+ US state) sell USDC on Solana for fiat?
    def offramp_available?(country:, subdivision: nil)
      available?(direction: :sell, country: country, subdivision: subdivision)
    end

    private

    def available?(direction:, country:, subdivision:)
      country = country.to_s.upcase.presence
      subdivision = subdivision.to_s.upcase.presence
      return false if country.nil?
      # subdivision is required for US — without a detected state we can't
      # honor state-level restrictions, so fail closed.
      return false if country == "US" && subdivision.nil?

      config  = direction == :buy ? buy_config : sell_config
      return false unless country_supported?(config, country, subdivision)

      options = direction == :buy ? buy_options(country: country, subdivision: subdivision) : sell_options(country: country, subdivision: subdivision)
      currencies_key = direction == :buy ? "purchase_currencies" : "sell_currencies"
      usdc_on_solana?(options, currencies_key)
    rescue Cdp::Client::Error => e
      ErrorLog.capture!(e)
      false
    end

    def country_supported?(config, country, subdivision)
      countries = unwrap(config)["countries"]
      return false unless countries.is_a?(Array)

      entry = countries.find { |c| c.is_a?(Hash) && c["id"].to_s.upcase == country }
      return false unless entry

      subdivisions = entry["subdivisions"]
      # Subdivision restrictions only apply when the API lists them (US states).
      if subdivisions.is_a?(Array) && subdivisions.any?
        return false if subdivision.nil?
        return subdivisions.map { |s| s.to_s.upcase }.include?(subdivision)
      end
      true
    end

    # USDC must appear in the given currencies list with a Solana network entry.
    def usdc_on_solana?(options, currencies_key)
      currencies = unwrap(options)[currencies_key]
      return false unless currencies.is_a?(Array)

      currencies.any? do |currency|
        next false unless currency.is_a?(Hash)
        next false unless %w[symbol code id name].any? { |k| currency[k].to_s.casecmp?("USDC") }

        networks = currency["networks"]
        networks.is_a?(Array) && networks.any? { |n| solana_network?(n) }
      end
    end

    # "solana" vs "solana-mainnet"-style slugs appear across doc examples —
    # match loosely on every plausible name field.
    def solana_network?(network)
      values =
        case network
        when Hash   then network.values_at("name", "id", "display_name", "chain_id")
        when String then [network]
        else []
        end
      values.compact.any? { |v| v.to_s.downcase.include?("solana") }
    end

    # Some CDP responses nest the payload under "data" (open question 8).
    def unwrap(payload)
      return {} unless payload.is_a?(Hash)
      inner = payload["data"]
      inner.is_a?(Hash) ? inner : payload
    end

    def options_params(country, subdivision)
      params = { country: country, networks: "solana" }
      params[:subdivision] = subdivision if subdivision.present?
      params
    end

    def options_key(kind, country, subdivision)
      "#{kind}/#{country.to_s.upcase}/#{subdivision.to_s.upcase}"
    end

    # Per-request @memo over Rails.cache (null_store in dev/test makes the
    # cache a no-op — the @ivar layer still saves the repeat HTTP calls).
    def fetch(key, &block)
      @memo[key] ||= Rails.cache.fetch("cdp/catalog/#{key}", expires_in: CACHE_TTL, &block)
    end
  end
end
