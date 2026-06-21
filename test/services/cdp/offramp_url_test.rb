require "test_helper"

class Cdp::OfframpUrlTest < ActiveSupport::TestCase
  REQUIRED = {
    session_token: "sess-token",
    partner_user_ref: "tm-1-42",
    redirect_url: "https://turfmonster.media/cdp/offramp/return"
  }.freeze

  test "builds the hosted sell URL with USDC-on-Solana defaults" do
    url = Cdp::OfframpUrl.build(**REQUIRED)
    uri = URI(url)
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "pay.coinbase.com", uri.host
    assert_equal "/v3/sell/input", uri.path
    assert_equal "sess-token", params["sessionToken"]
    assert_equal "tm-1-42", params["partnerUserRef"]
    assert_equal REQUIRED[:redirect_url], params["redirectUrl"]
    assert_equal "solana", params["defaultNetwork"]
    assert_equal "USDC", params["defaultAsset"]
  end

  test "sessionToken, partnerUserRef, and redirectUrl are ALL required for offramp" do
    REQUIRED.each_key do |missing|
      error = assert_raises(ArgumentError) { Cdp::OfframpUrl.build(**REQUIRED.merge(missing => nil)) }
      assert_match(/#{missing}/, error.message)
    end
  end

  test "enforces the < 50-char partnerUserRef limit" do
    assert Cdp::OfframpUrl.build(**REQUIRED, partner_user_ref: "x" * 49)
    assert_raises(ArgumentError) { Cdp::OfframpUrl.build(**REQUIRED.merge(partner_user_ref: "x" * 50)) }
  end

  test "presetCryptoAmount and presetFiatAmount are mutually exclusive" do
    assert Cdp::OfframpUrl.build(**REQUIRED, preset_crypto_amount: 25)
    assert Cdp::OfframpUrl.build(**REQUIRED, preset_fiat_amount: 25)
    assert_raises(ArgumentError) do
      Cdp::OfframpUrl.build(**REQUIRED, preset_crypto_amount: 25, preset_fiat_amount: 25)
    end
  end

  test "defaultCashoutMethod must be a documented value" do
    url = Cdp::OfframpUrl.build(**REQUIRED, default_cashout_method: "ACH_BANK_ACCOUNT")
    assert_equal "ACH_BANK_ACCOUNT", Rack::Utils.parse_query(URI(url).query)["defaultCashoutMethod"]

    assert_raises(ArgumentError) { Cdp::OfframpUrl.build(**REQUIRED, default_cashout_method: "VENMO") }
  end

  test "rejects undocumented params" do
    assert_raises(ArgumentError) { Cdp::OfframpUrl.build(**REQUIRED, default_experience: "send") }
  end
end
