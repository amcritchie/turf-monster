require "test_helper"

class Cdp::OnrampUrlTest < ActiveSupport::TestCase
  REQUIRED = {
    session_token: "sess-token",
    partner_user_ref: "tm-1-42",
    redirect_url: "https://app.turfmonster.media/cdp/onramp/return"
  }.freeze

  test "builds the hosted buy URL with USDC-on-Solana defaults" do
    url = Cdp::OnrampUrl.build(**REQUIRED)
    uri = URI(url)
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "pay.coinbase.com", uri.host
    assert_equal "/buy/select-asset", uri.path
    assert_equal "sess-token", params["sessionToken"]
    # partnerUserRef, NOT partnerUserId (that's the sell-quote API's param).
    assert_equal "tm-1-42", params["partnerUserRef"]
    assert_equal REQUIRED[:redirect_url], params["redirectUrl"]
    assert_equal "solana", params["defaultNetwork"]
    assert_equal "USDC", params["defaultAsset"]
  end

  test "passes documented optional params through under their camelCase names" do
    url = Cdp::OnrampUrl.build(**REQUIRED, preset_fiat_amount: 19, default_experience: "buy", fiat_currency: "USD")
    params = Rack::Utils.parse_query(URI(url).query)

    assert_equal "19", params["presetFiatAmount"]
    assert_equal "buy", params["defaultExperience"]
    assert_equal "USD", params["fiatCurrency"]
  end

  test "rejects undocumented params" do
    assert_raises(ArgumentError) { Cdp::OnrampUrl.build(**REQUIRED, destination_wallets: "deprecated") }
  end

  test "enforces required params" do
    REQUIRED.each_key do |missing|
      error = assert_raises(ArgumentError) { Cdp::OnrampUrl.build(**REQUIRED.merge(missing => nil)) }
      assert_match(/#{missing}/, error.message)
    end
  end

  test "enforces the < 50-char partnerUserRef limit" do
    assert Cdp::OnrampUrl.build(**REQUIRED, partner_user_ref: "x" * 49)
    assert_raises(ArgumentError) { Cdp::OnrampUrl.build(**REQUIRED.merge(partner_user_ref: "x" * 50)) }
  end
end
