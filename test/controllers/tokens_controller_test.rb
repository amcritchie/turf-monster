require "test_helper"
require "minitest/mock"

class TokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  test "buy requires login" do
    get tokens_buy_path
    assert_redirected_to login_path
  end

  test "buy renders for logged in user" do
    log_in_as @jordan
    get tokens_buy_path
    assert_response :success
    assert_select "h1", text: /Entry Tokens/
  end

  test "dev_mint requires admin" do
    log_in_as @jordan
    post tokens_dev_mint_path, params: { quantity: 1 }
    assert_redirected_to tokens_buy_path
    assert_equal 0, @jordan.entry_tokens.count
  end

  test "dev_mint creates tokens for admin (devnet)" do
    log_in_as @alex
    post tokens_dev_mint_path, params: { quantity: 3 }
    assert_redirected_to tokens_buy_path
    assert_equal 3, @alex.entry_tokens.purchased.count
    assert @alex.entry_tokens.pluck(:source).all? { |s| s == "dev" }
  end

  test "dev_mint rejects unknown pack quantity" do
    log_in_as @alex
    post tokens_dev_mint_path, params: { quantity: 7 }
    assert_redirected_to tokens_buy_path
    assert_equal 0, @alex.entry_tokens.count
  end

  test "stripe_checkout requires login" do
    post tokens_stripe_checkout_path, params: { quantity: 1 }
    assert_redirected_to login_path
  end

  test "stripe_checkout rejects unknown pack quantity" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    post tokens_stripe_checkout_path, params: { quantity: 7 }
    assert_redirected_to tokens_buy_path
    assert_match(/Unknown pack/, flash[:alert])
  end

  test "stripe_checkout requires connected wallet" do
    log_in_as @jordan
    post tokens_stripe_checkout_path, params: { quantity: 1 }
    assert_redirected_to tokens_buy_path
    assert_match(/Connect a wallet/, flash[:alert])
  end

  test "stripe_checkout redirects to Stripe session URL" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    fake_session = Struct.new(:url).new("https://stripe.example/cs_test_xyz")
    with_stripe_enabled do
      Stripe::Checkout::Session.stub :create, fake_session do
        post tokens_stripe_checkout_path, params: { quantity: 3 }
      end
    end
    assert_redirected_to "https://stripe.example/cs_test_xyz"
  end

  test "stripe_checkout bounces with helpful alert when not configured" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    with_stripe_disabled do
      post tokens_stripe_checkout_path, params: { quantity: 1 }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/Card checkout isn't configured/, flash[:alert])
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

  test "status returns ready=true when tokens exist for session" do
    log_in_as @jordan
    EntryToken.create!(user: @jordan, status: "purchased", source: "stripe", source_ref: "cs_done", price_cents: 19_00)
    EntryToken.create!(user: @jordan, status: "purchased", source: "stripe", source_ref: "cs_done", price_cents: 19_00)
    get tokens_status_path, params: { session_id: "cs_done" }
    body = JSON.parse(response.body)
    assert_equal true, body["ready"]
    assert_equal 2, body["minted"]
    assert_equal 2, body["balance"]
  end

  test "status scopes session_id to current user (no cross-user leak)" do
    EntryToken.create!(user: @alex, status: "purchased", source: "stripe", source_ref: "cs_alex_only", price_cents: 19_00)
    log_in_as @jordan
    get tokens_status_path, params: { session_id: "cs_alex_only" }
    body = JSON.parse(response.body)
    assert_equal false, body["ready"]
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
