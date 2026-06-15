require "test_helper"
require "minitest/mock"

# PayPal-rails onramp: TokensController#paypal_order / #paypal_capture and the
# order_id branch of #status. Mirrors the stripe_checkout coverage in
# tokens_controller_test.rb.
class TokensPaypalTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  # ── paypal_order ────────────────────────────────────────────────────────

  test "paypal_order requires login" do
    post tokens_paypal_order_path, params: { pack: "single" }, as: :json
    assert_response :unauthorized
  end

  test "paypal_order rejects an unknown pack" do
    log_in_as_with_wallet @jordan
    post tokens_paypal_order_path, params: { pack: "bogus" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Unknown or unavailable/, JSON.parse(response.body)["error"])
  end

  test "paypal_order requires connected wallet" do
    log_in_as @jordan
    with_paypal_enabled do
      post tokens_paypal_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Connect a wallet/, JSON.parse(response.body)["error"])
  end

  test "paypal_order refuses when provider flag is not paypal (deploy-inert gate)" do
    log_in_as_with_wallet @jordan
    # Test env default: PAYMENT_PROVIDER unset -> provider "none".
    post tokens_paypal_order_path, params: { pack: "single" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/isn't enabled/, JSON.parse(response.body)["error"])
    assert_equal 0, PaypalPurchase.count
  end

  test "paypal_order blocks a payment-risk-flagged user (OPSEC-036)" do
    log_in_as_with_wallet @jordan
    @jordan.update!(payment_risk_flag: true)
    with_paypal_enabled do
      post tokens_paypal_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, PaypalPurchase.count
  end

  test "paypal_order blocks a frozen account (B4 / OPSEC-048)" do
    log_in_as_with_wallet @jordan
    @jordan.freeze_for_payment_risk!(reason: "test freeze")
    with_paypal_enabled do
      post tokens_paypal_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, PaypalPurchase.count
  end

  test "paypal_order creates a pending purchase with SERVER-derived amount and returns the order id" do
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new(order_id: "ORDER_HAPPY")
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        post tokens_paypal_order_path, params: { pack: "trio", price_cents: 1 }, as: :json
      end
    end
    assert_response :success
    assert_equal "ORDER_HAPPY", JSON.parse(response.body)["order_id"]

    purchase = PaypalPurchase.for_order("ORDER_HAPPY").first
    assert_equal @jordan.id, purchase.user_id
    assert_equal "trio", purchase.pack_id
    assert_equal 3, purchase.quantity
    assert_equal 49_00, purchase.price_cents, "amount must come from the pack, never the client"
    assert_equal "pending", purchase.status
    assert_equal @jordan.solana_address, purchase.wallet_address
    assert_equal 1, client.created_orders.length
  end

  test "paypal_order records the contest context when given" do
    log_in_as_with_wallet @jordan
    contest = contests(:one)
    with_paypal_enabled do
      Paypal::Client.stub :new, FakePaypalClient.new(order_id: "ORDER_CTX") do
        post tokens_paypal_order_path, params: { pack: "single", contest: contest.slug }, as: :json
      end
    end
    assert_equal contest.slug, PaypalPurchase.for_order("ORDER_CTX").first.contest_slug
  end

  test "paypal_order marks the purchase failed when the PayPal call raises" do
    log_in_as_with_wallet @jordan
    raising_client = Object.new
    def raising_client.create_order(**)
      raise Paypal::Client::Error, "PayPal down"
    end
    with_paypal_enabled do
      Paypal::Client.stub :new, raising_client do
        post tokens_paypal_order_path, params: { pack: "single" }, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "failed", PaypalPurchase.last.status
  end

  # ── paypal_capture ──────────────────────────────────────────────────────

  test "paypal_capture without an order_id is a bad request" do
    log_in_as_with_wallet @jordan
    with_paypal_enabled do
      post tokens_paypal_capture_path, as: :json
    end
    assert_response :bad_request
  end

  test "paypal_capture 404s an order that is not the current user's" do
    create_pending_purchase(user: @alex, order_id: "ORDER_ALEX")
    log_in_as_with_wallet @jordan
    with_paypal_enabled do
      post tokens_paypal_capture_path, params: { order_id: "ORDER_ALEX" }, as: :json
    end
    assert_response :not_found
  end

  test "paypal_capture validates, marks captured, and enqueues the mint job" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_CAP", pack_id: "trio", quantity: 3, price_cents: 49_00)
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new(
      capture_response: FakePaypalClient.completed_capture_response(
        order_id: "ORDER_CAP", amount: "49.00", capture_id: "CAP_OK"
      )
    )
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_enqueued_with(job: TokenPurchaseJob, args: [{
          user_id: @jordan.id, pack_id: "trio", wallet_address: purchase.wallet_address,
          purchase_type: "paypal", paypal_order_id: "ORDER_CAP"
        }]) do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_CAP" }, as: :json
        end
      end
    end
    assert_response :success
    assert_equal "captured", JSON.parse(response.body)["status"]
    purchase.reload
    assert_equal "captured", purchase.status
    assert_equal "CAP_OK", purchase.capture_id
  end

  test "paypal_capture rejects an amount mismatch — no status change, no job" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_BAD", pack_id: "trio", quantity: 3, price_cents: 49_00)
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new(
      capture_response: FakePaypalClient.completed_capture_response(order_id: "ORDER_BAD", amount: "5.00")
    )
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_BAD" }, as: :json
        end
      end
    end
    assert_response :unprocessable_entity
    assert_equal "pending", purchase.reload.status
  end

  test "paypal_capture rejects a currency mismatch — no status change, no job" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_EUR")
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new(
      capture_response: FakePaypalClient.completed_capture_response(order_id: "ORDER_EUR", amount: "19.00", currency: "EUR")
    )
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_EUR" }, as: :json
        end
      end
    end
    assert_response :unprocessable_entity
    assert_equal "pending", purchase.reload.status
  end

  test "paypal_capture blocks a payment-risk-flagged user before any money moves (OPSEC-036)" do
    # The flag can flip between order creation and capture — the capture leg
    # must re-check it (paypal_order/stripe_checkout gate parity).
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_FLAG")
    log_in_as_with_wallet @jordan
    @jordan.update!(payment_risk_flag: true)
    client = FakePaypalClient.new
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_FLAG" }, as: :json
        end
      end
    end
    assert_response :forbidden
    assert_equal 0, client.captured_orders.length, "must not hit PayPal for a flagged account"
    assert_equal "pending", purchase.reload.status
  end

  test "paypal_capture treats a PENDING capture (eCheck/review hold) as processing, never a failure" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_HOLD")
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new(
      capture_response: FakePaypalClient.completed_capture_response(
        order_id: "ORDER_HOLD", amount: "19.00", capture_status: "PENDING"
      )
    )
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_HOLD" }, as: :json
        end
      end
    end
    # 200 + "processing" — a 422 here told the (already charged) buyer to
    # "try again", and the retry created a second order = real double charge.
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "processing", json["status"]
    assert_nil json["error"], "a hold is not an error — no retry invitation"
    assert_equal "pending", purchase.reload.status,
                 "row stays pending so PAYMENT.CAPTURE.COMPLETED wins the CAS when the hold clears"
  end

  test "paypal_capture is idempotent — non-pending purchase returns status without re-capturing" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_DUP")
    purchase.begin_fulfillment!(capture_id: "CAP_FIRST")
    log_in_as_with_wallet @jordan
    client = FakePaypalClient.new
    with_paypal_enabled do
      Paypal::Client.stub :new, client do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post tokens_paypal_capture_path, params: { order_id: "ORDER_DUP" }, as: :json
        end
      end
    end
    assert_response :success
    assert_equal "captured", JSON.parse(response.body)["status"]
    assert_equal 0, client.captured_orders.length, "must not hit PayPal again"
  end

  # ── rendering (buy page + auth-modal picker branch) ────────────────────

  test "buy renders the PayPal/Venmo purchase UI when the paypal provider is active" do
    log_in_as @jordan
    with_paypal_enabled do
      get tokens_buy_path
    end
    assert_response :success
    # Page flow: SDK loader + factory + the buttons block.
    assert_match "window.loadPaypalSdk", response.body
    assert_match "paypalButtons({ flow: 'page'", response.body
    assert_match 'x-ref="venmoSlot"', response.body
    # Modal picker branch (layout-level auth modal) swaps to PayPal too.
    assert_match "paypalButtons({ flow: 'modal'", response.body
    # The Stripe checkout form is fully replaced on the page.
    assert_no_match %r{action="/tokens/stripe_checkout}, response.body
  end

  test "buy page SDK URL carries enable-funding=venmo and sandbox-only buyer-country" do
    log_in_as @jordan
    with_paypal_enabled do
      get tokens_buy_path
    end
    assert_match "enable-funding=venmo", response.body
    # Test env has no PAYPAL_ENV → Paypal::Client.sandbox? → buyer-country
    # MUST be present (sandbox never shows Venmo without it; live rejects it).
    assert_match "buyer-country=US", response.body
  end

  test "buy page SDK URL omits buyer-country in the live env (the live SDK rejects it)" do
    log_in_as @jordan
    with_paypal_enabled do
      Paypal::Client.stub :env, "live" do
        get tokens_buy_path
      end
    end
    assert_match "enable-funding=venmo", response.body
    # Dropping the sandbox? conditional in _paypal_sdk.html.erb would break
    # live checkout at SDK load on day one of the flip — guard the absence.
    assert_no_match(/buyer-country/, response.body)
  end

  test "buy renders zero PayPal output when provider is stripe (deploy-inert gate)" do
    log_in_as @jordan
    get tokens_buy_path
    assert_response :success
    assert_no_match(/paypalButtons|loadPaypalSdk|venmoSlot/, response.body)
    assert_match %r{action="/tokens/stripe_checkout}, response.body
  end

  test "stripe pack buttons are disabled everywhere when the provider is none (no dead checkout)" do
    log_in_as @jordan
    with_provider("none") do
      get tokens_buy_path
    end
    assert_response :success
    # Both the buy page AND the layout-level auth-modal picker render the
    # Stripe branch; with provider=none every pack button must be inert —
    # Payments documents "none — token purchases hidden", and the endpoint
    # refuses (see the stripe_checkout gate test below).
    assert_select "form[action^='/tokens/stripe_checkout'] button:not([disabled])", count: 0
  end

  # ── stripe_checkout provider gate (the flag retires the endpoint) ───────

  test "stripe_checkout refuses when the active provider is not stripe" do
    log_in_as_with_wallet @jordan
    original_enabled = Rails.application.config.x.stripe_enabled
    Rails.application.config.x.stripe_enabled = true
    begin
      with_paypal_enabled do
        post tokens_stripe_checkout_path, params: { pack: "single" }
      end
    ensure
      Rails.application.config.x.stripe_enabled = original_enabled
    end
    # Stale tabs / scripted clients must not create sessions against the
    # blocked Stripe account after the flip.
    assert_redirected_to tokens_buy_path
    assert_match(/currently disabled/, flash[:alert])
  end

  # ── routing: format suffix must not sidestep the rack-attack throttles ──

  test "paypal endpoints reject a format suffix (throttles match exact paths)" do
    assert_equal "paypal_order",
                 Rails.application.routes.recognize_path("/tokens/paypal_order", method: :post)[:action]
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/tokens/paypal_order.json", method: :post)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/tokens/paypal_capture.json", method: :post)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/webhooks/paypal.json", method: :post)
    end
  end

  # ── status (order_id branch) ────────────────────────────────────────────

  test "status resolves a PayPal purchase by order_id" do
    purchase = create_pending_purchase(user: @jordan, order_id: "ORDER_STATUS")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig_0"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { order_id: "ORDER_STATUS" }
    json = JSON.parse(response.body)
    assert json["ready"]
    assert_equal 1, json["minted"]
  end

  test "status scopes order_id to current_user" do
    purchase = create_pending_purchase(user: @alex, order_id: "ORDER_XUSER")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { order_id: "ORDER_XUSER" }
    refute JSON.parse(response.body)["ready"]
  end

  test "status without session_id or order_id is a bad request" do
    log_in_as @jordan
    get tokens_status_path
    assert_response :bad_request
  end

  private

  def log_in_as_with_wallet(user)
    user.update!(web2_solana_address: "TestWalletAddr#{SecureRandom.hex(3)}", encrypted_web2_solana_private_key: "x")
    log_in_as user
  end

  def create_pending_purchase(user:, order_id:, pack_id: "single", quantity: 1, price_cents: 19_00)
    PaypalPurchase.create!(
      user: user,
      paypal_order_id: order_id,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: "TestWalletAddr#{SecureRandom.hex(3)}",
      status: "pending"
    )
  end

  def with_paypal_enabled
    original_enabled = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.paypal_enabled = true
    with_provider("paypal") { yield }
  ensure
    Rails.application.config.x.paypal_enabled = original_enabled
  end

  def with_provider(provider)
    original = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = provider
    yield
  ensure
    Rails.application.config.x.payment_provider = original
  end
end
