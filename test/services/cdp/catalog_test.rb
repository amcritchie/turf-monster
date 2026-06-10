require "test_helper"

class Cdp::CatalogTest < ActiveSupport::TestCase
  # Canned-response fake following the house FakeClient pattern (see
  # Solana::ClientLoggerTest) — no real HTTP. Counts calls per path so the
  # memoization tests can assert fetch-once behavior.
  class FakeClient
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def get(path, params = {})
      @calls << [path, params]
      response = @responses.fetch(path) { raise Cdp::Client::ApiError.new("unstubbed path #{path}") }
      response.respond_to?(:call) ? response.call(params) : response
    end
  end

  BUY_CONFIG = {
    "countries" => [
      { "id" => "US", "subdivisions" => %w[CA TX], "payment_methods" => [{ "id" => "CARD" }] },
      { "id" => "GB", "subdivisions" => [], "payment_methods" => [{ "id" => "CARD" }] }
    ]
  }.freeze

  USDC_SOLANA_BUY_OPTIONS = {
    "purchase_currencies" => [
      { "id" => "usdc-uuid", "symbol" => "USDC",
        "networks" => [{ "name" => "solana", "display_name" => "Solana" }] },
      { "id" => "eth-uuid", "symbol" => "ETH",
        "networks" => [{ "name" => "ethereum" }] }
    ]
  }.freeze

  SELL_CONFIG = BUY_CONFIG

  USDC_SOLANA_SELL_OPTIONS = {
    "sell_currencies" => [
      { "id" => "usdc-uuid", "symbol" => "USDC",
        "networks" => [{ "name" => "solana" }] }
    ],
    "cashout_currencies" => [{ "id" => "USD", "limits" => [] }]
  }.freeze

  def catalog_with(responses)
    client = FakeClient.new(responses)
    [Cdp::Catalog.new(client: client), client]
  end

  def buy_responses(config: BUY_CONFIG, options: USDC_SOLANA_BUY_OPTIONS)
    { "/onramp/v1/buy/config" => config, "/onramp/v1/buy/options" => options }
  end

  def sell_responses(config: SELL_CONFIG, options: USDC_SOLANA_SELL_OPTIONS)
    { "/onramp/v1/sell/config" => config, "/onramp/v1/sell/options" => options }
  end

  # ── Onramp gating ──────────────────────────────────────────────────────────

  test "onramp available for a supported US state with USDC on Solana" do
    catalog, client = catalog_with(buy_responses)
    assert catalog.onramp_available?(country: "US", subdivision: "CA")
    # subdivision is REQUIRED for country=US — it must reach the options call.
    options_call = client.calls.find { |path, _| path == "/onramp/v1/buy/options" }
    assert_equal({ country: "US", networks: "solana", subdivision: "CA" }, options_call.last)
  end

  test "onramp fails closed for US without a subdivision (state restrictions)" do
    catalog, client = catalog_with(buy_responses)
    assert_not catalog.onramp_available?(country: "US")
    assert_empty client.calls, "must not even hit the API without a US state"
  end

  test "onramp unavailable for a US state outside the subdivision list" do
    catalog, _client = catalog_with(buy_responses)
    assert_not catalog.onramp_available?(country: "US", subdivision: "NY")
  end

  test "onramp unavailable for an unsupported country" do
    catalog, _client = catalog_with(buy_responses)
    assert_not catalog.onramp_available?(country: "FR")
  end

  test "non-US country with no subdivision restrictions needs no subdivision" do
    catalog, _client = catalog_with(buy_responses)
    assert catalog.onramp_available?(country: "GB")
  end

  test "onramp unavailable when USDC has no Solana network in the options" do
    eth_only = {
      "purchase_currencies" => [
        { "symbol" => "USDC", "networks" => [{ "name" => "ethereum" }] }
      ]
    }
    catalog, _client = catalog_with(buy_responses(options: eth_only))
    assert_not catalog.onramp_available?(country: "US", subdivision: "CA")
  end

  test "blank country fails closed" do
    catalog, client = catalog_with(buy_responses)
    assert_not catalog.onramp_available?(country: nil)
    assert_not catalog.onramp_available?(country: "")
    assert_empty client.calls
  end

  # ── Defensive parsing (spec open question 8) ───────────────────────────────

  test "unwraps a data-nested config and matches solana-mainnet style slugs" do
    nested = {
      "data" => {
        "countries" => [{ "id" => "US", "subdivisions" => %w[CA] }]
      }
    }
    mainnet_slug = {
      "data" => {
        "purchase_currencies" => [
          { "symbol" => "usdc", "networks" => [{ "name" => "solana-mainnet" }] }
        ]
      }
    }
    catalog, _client = catalog_with(buy_responses(config: nested, options: mainnet_slug))
    assert catalog.onramp_available?(country: "US", subdivision: "CA")
  end

  # ── Offramp gating ─────────────────────────────────────────────────────────

  test "offramp available when sell config + sell options carry USDC on Solana" do
    catalog, client = catalog_with(sell_responses)
    assert catalog.offramp_available?(country: "US", subdivision: "TX")
    assert(client.calls.any? { |path, _| path == "/onramp/v1/sell/config" })
    assert(client.calls.any? { |path, _| path == "/onramp/v1/sell/options" })
  end

  test "offramp unavailable when sell_currencies lack USDC" do
    no_usdc = { "sell_currencies" => [], "cashout_currencies" => [] }
    catalog, _client = catalog_with(sell_responses(options: no_usdc))
    assert_not catalog.offramp_available?(country: "US", subdivision: "TX")
  end

  # ── Caching / memoization ──────────────────────────────────────────────────

  test "per-request memoization — repeated checks hit the API once per endpoint" do
    catalog, client = catalog_with(buy_responses)
    3.times { assert catalog.onramp_available?(country: "US", subdivision: "CA") }
    # Rails.cache is :null_store in test, so this proves the @ivar layer alone.
    assert_equal 2, client.calls.size, "expected one config + one options call"
  end

  test "distinct subdivisions are cached separately" do
    catalog, client = catalog_with(buy_responses)
    catalog.onramp_available?(country: "US", subdivision: "CA")
    catalog.onramp_available?(country: "US", subdivision: "TX")
    options_calls = client.calls.count { |path, _| path == "/onramp/v1/buy/options" }
    assert_equal 2, options_calls
  end

  # ── Fail closed on API errors ──────────────────────────────────────────────

  test "a CDP API failure logs an ErrorLog and returns false (never raises)" do
    boom = ->(_params) { raise Cdp::Client::ApiError.new("CDP 500: boom", status_code: 500) }
    catalog, _client = catalog_with("/onramp/v1/buy/config" => boom)

    result = nil
    assert_difference -> { ErrorLog.count }, 1 do
      result = catalog.onramp_available?(country: "US", subdivision: "CA")
    end
    assert_not result
  end
end
