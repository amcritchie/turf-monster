require "test_helper"
require "minitest/mock"

class TokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  test "buy requires login" do
    get tokens_buy_path
    assert_redirected_to signin_path
  end

  test "buy renders for logged in user" do
    log_in_as @jordan
    get tokens_buy_path
    assert_response :success
    assert_select "h1", text: /Entry Tokens/
  end

  test "dev_mint redirects non-admin with admin-only alert" do
    log_in_as @jordan
    post tokens_dev_mint_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_match(/admin.*devnet/i, flash[:alert])
  end

  test "dev_mint creates requested quantity of on-chain tokens for an admin" do
    log_in_as @alex
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post tokens_dev_mint_path, params: { pack: "trio" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/Minted 3 test tokens?/, flash[:notice])
    assert_equal 3, vault.mint_calls.length
    assert vault.mint_calls.all? { |r| r.start_with?("dev:") }
  end

  test "dev_mint rejects an unknown pack (kept — pure controller logic)" do
    log_in_as @alex
    post tokens_dev_mint_path, params: { pack: "bogus" }
    assert_redirected_to tokens_buy_path
  end

  test "stripe_checkout requires login" do
    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to signin_path
  end

  test "stripe_checkout rejects an unknown pack" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    post tokens_stripe_checkout_path, params: { pack: "bogus" }
    assert_redirected_to tokens_buy_path
    assert_match(/Unknown or unavailable/, flash[:alert])
  end

  test "stripe_checkout requires connected wallet" do
    log_in_as @jordan
    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_match(/Connect a wallet/, flash[:alert])
  end

  test "stripe_checkout redirects to Stripe session URL" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    fake_session = Struct.new(:url).new("https://stripe.example/cs_test_xyz")
    with_stripe_enabled do
      Stripe::Checkout::Session.stub :create, fake_session do
        post tokens_stripe_checkout_path, params: { pack: "trio" }
      end
    end
    assert_redirected_to "https://stripe.example/cs_test_xyz"
  end

  test "stripe_checkout bounces with helpful alert when not configured" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    with_stripe_disabled do
      post tokens_stripe_checkout_path, params: { pack: "single" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/Card checkout isn't configured/, flash[:alert])
  end

  test "stripe_checkout blocks a payment-risk-flagged user (OPSEC-036)" do
    log_in_as @jordan
    @jordan.update!(
      web2_solana_address: "TestWalletAddr123",
      encrypted_web2_solana_private_key: "x",
      payment_risk_flag: true
    )
    with_stripe_enabled do
      post tokens_stripe_checkout_path, params: { pack: "single" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/disabled on this account/, flash[:alert])
  end

  test "processing requires session_id" do
    log_in_as @jordan
    get tokens_processing_path
    assert_redirected_to tokens_buy_path
  end

  test "processing renders with session_id" do
    log_in_as @jordan
    get tokens_processing_path, params: { session_id: "cs_test_processing" }
    assert_response :success
  end

  test "status returns ready=false when no tokens for session" do
    log_in_as @jordan
    get tokens_status_path, params: { session_id: "cs_unknown" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["ready"]
    assert_equal 0, body["minted"]
  end

  test "status returns ready=true when StripePurchase is minted" do
    log_in_as @jordan
    sid = "cs_test_status_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @jordan, stripe_session_id: sid,
      quantity: 1, price_cents: 19_00, status: "minted",
      mint_tx_signatures: ["sig_0"].to_json
    )
    get tokens_status_path, params: { session_id: sid }
    json = JSON.parse(response.body)
    assert json["ready"]
    assert_equal 1, json["minted"]
  end

  test "status scopes session_id to current_user — other users see ready=false" do
    sid = "cs_test_xuser_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @alex, stripe_session_id: sid,
      quantity: 1, price_cents: 19_00, status: "minted",
      mint_tx_signatures: ["sig"].to_json
    )
    log_in_as @jordan
    get tokens_status_path, params: { session_id: sid }
    refute JSON.parse(response.body)["ready"]
  end

  private

  def with_stripe_enabled
    toggle_stripe(true) { yield }
  end

  def with_stripe_disabled
    toggle_stripe(false) { yield }
  end

  def toggle_stripe(value)
    original = Rails.application.config.x.stripe_enabled
    Rails.application.config.x.stripe_enabled = value
    yield
  ensure
    Rails.application.config.x.stripe_enabled = original
  end
end
