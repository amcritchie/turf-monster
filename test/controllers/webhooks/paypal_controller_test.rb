require "test_helper"
require "minitest/mock"

# PayPal webhook → mint pipeline. Signature verification is the entire defense
# between an attacker and free token minting (Webhooks::StripeControllerTest
# parity); the FakePaypalClient's verify_result stands in for PayPal's
# verify-webhook-signature API.
class Webhooks::PaypalControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:jordan)
    @user.update!(
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
  end

  # ── Signature verification ─────────────────────────────────────────────

  test "rejects an event with a failed signature verification → 400" do
    client = FakePaypalClient.new(verify_result: false)
    Paypal::Client.stub :new, client do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: create_purchase))
      end
    end
    assert_response :bad_request
    assert_equal 1, client.verify_calls.length
  end

  test "rejects malformed JSON → 400 before any verification" do
    # text/plain so the body reaches the controller's own JSON.parse guard;
    # malformed application/json gets a framework-level 400 even earlier.
    client = FakePaypalClient.new
    Paypal::Client.stub :new, client do
      post "/webhooks/paypal", params: "not-json{", headers: { "Content-Type" => "text/plain" }
    end
    assert_response :bad_request
    assert_equal 0, client.verify_calls.length
  end

  test "verification receives the RAW request body" do
    client = FakePaypalClient.new
    event = { "id" => "WH-raw", "event_type" => "UNKNOWN.EVENT", "resource" => {} }
    raw = event.to_json
    Paypal::Client.stub :new, client do
      post "/webhooks/paypal", params: raw, headers: { "Content-Type" => "application/json" }
    end
    assert_response :ok
    assert_equal raw, client.verify_calls.first[:raw_body]
  end

  # ── OPSEC-033 parity: refuse sandbox events in production ──────────────

  test "production refuses events when the client is sandbox-configured" do
    purchase = create_purchase
    Rails.env.stub :production?, true do
      Paypal::Client.stub :new, FakePaypalClient.new do
        assert_no_enqueued_jobs do
          post_webhook(capture_completed_event(purchase: purchase))
        end
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "production refuses an event self-referencing the sandbox API host" do
    purchase = create_purchase
    event = capture_completed_event(purchase: purchase)
    event["links"] = [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-1", "rel" => "self" }]
    Rails.env.stub :production?, true do
      Paypal::Client.stub :env, "live" do
        Paypal::Client.stub :new, FakePaypalClient.new do
          assert_no_enqueued_jobs do
            post_webhook(event)
          end
        end
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  # ── PAYMENT.CAPTURE.COMPLETED ──────────────────────────────────────────

  test "capture completed validates then enqueues the mint job" do
    purchase = create_purchase(pack_id: "trio", quantity: 3, price_cents: 49_00)
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(capture_completed_event(purchase: purchase, amount: "49.00", capture_id: "CAP_WH"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status
    assert_equal "CAP_WH", purchase.capture_id
  end

  test "capture completed with an amount mismatch never mints" do
    purchase = create_purchase(pack_id: "trio", quantity: 3, price_cents: 49_00)
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: purchase, amount: "0.49"))
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "capture completed for an unmatched purchase acks 200 without minting" do
    event = capture_completed_event(purchase: nil, custom_id: "paypal_purchase:999999")
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(event)
      end
    end
    assert_response :ok
  end

  test "capture completed redelivery after fulfillment re-enqueues only when unminted" do
    purchase = create_purchase
    purchase.begin_fulfillment!(capture_id: "CAP_X")
    # Stranded captured-but-unminted → safe re-enqueue (job is idempotent).
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(capture_completed_event(purchase: purchase, capture_id: "CAP_X"))
      end
    end

    purchase.mark_minted!(["sig_0"])
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: purchase, capture_id: "CAP_X"))
      end
    end
    assert_equal "minted", purchase.reload.status
  end

  # ── CHECKOUT.ORDER.APPROVED (client-died fallback) ─────────────────────

  test "order approved captures server-side when the purchase is still pending" do
    purchase = create_purchase(order_id: "ORDER_FB", pack_id: "trio", quantity: 3, price_cents: 49_00)
    client = FakePaypalClient.new(
      capture_response: FakePaypalClient.completed_capture_response(
        order_id: "ORDER_FB", amount: "49.00", capture_id: "CAP_FB"
      )
    )
    Paypal::Client.stub :new, client do
      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(order_approved_event(order_id: "ORDER_FB"))
      end
    end
    assert_response :ok
    assert_equal ["ORDER_FB"], client.captured_orders
    purchase.reload
    assert_equal "captured", purchase.status
    assert_equal "CAP_FB", purchase.capture_id
  end

  test "order approved is a no-op when fulfillment already started" do
    purchase = create_purchase(order_id: "ORDER_DONE")
    purchase.begin_fulfillment!(capture_id: "CAP_DONE")
    client = FakePaypalClient.new
    Paypal::Client.stub :new, client do
      assert_no_enqueued_jobs do
        post_webhook(order_approved_event(order_id: "ORDER_DONE"))
      end
    end
    assert_response :ok
    assert_equal 0, client.captured_orders.length
  end

  test "order approved survives an ORDER_ALREADY_CAPTURED race with a 200" do
    create_purchase(order_id: "ORDER_RACE")
    client = FakePaypalClient.new
    client.capture_raises = "PayPal POST → 422 ORDER_ALREADY_CAPTURED"
    Paypal::Client.stub :new, client do
      post_webhook(order_approved_event(order_id: "ORDER_RACE"))
    end
    assert_response :ok
  end

  # ── DENIED / REFUNDED / DISPUTE ────────────────────────────────────────

  test "capture denied marks the purchase failed" do
    purchase = create_purchase
    Paypal::Client.stub :new, FakePaypalClient.new do
      post_webhook(capture_completed_event(purchase: purchase, event_type: "PAYMENT.CAPTURE.DENIED", status: "DENIED"))
    end
    assert_response :ok
    assert_equal "failed", purchase.reload.status
  end

  test "capture refunded marks purchase refunded AND freezes the user (B4 / OPSEC-036+048)" do
    purchase = create_purchase
    purchase.begin_fulfillment!(capture_id: "CAP_REF")
    purchase.mark_minted!(["sig_0"])
    event = {
      "id" => "WH-refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED",
      "resource" => {
        "id" => "REFUND_1",
        "custom_id" => "paypal_purchase:#{purchase.id}",
        "links" => [{ "rel" => "up", "href" => "https://api-m.paypal.com/v2/payments/captures/CAP_REF" }]
      }
    }
    Paypal::Client.stub :new, FakePaypalClient.new do
      post_webhook(event)
    end
    assert_response :ok
    assert_equal "refunded", purchase.reload.status
    assert @user.reload.frozen?, "B4/OPSEC-048: refund should freeze the account"
    assert_match(/paypal\.refund/, @user.frozen_reason)
  end

  test "dispute flags AND freezes the buyer (B4 / OPSEC-036+048)" do
    purchase = create_purchase
    purchase.begin_fulfillment!(capture_id: "CAP_DISP")
    event = {
      "id" => "WH-dispute", "event_type" => "CUSTOMER.DISPUTE.CREATED",
      "resource" => {
        "dispute_id" => "PP-D-1234", "reason" => "UNAUTHORISED",
        "disputed_transactions" => [{ "seller_transaction_id" => "CAP_DISP" }]
      }
    }
    Paypal::Client.stub :new, FakePaypalClient.new do
      post_webhook(event)
    end
    assert_response :ok
    @user.reload
    assert @user.payment_risk_flag, "OPSEC-036: dispute should flip payment_risk_flag"
    assert @user.frozen?, "B4/OPSEC-048: dispute should freeze the account"
    assert_match(/paypal\.dispute/, @user.frozen_reason)
  end

  test "unknown event types return 200 and are ignored" do
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook({ "id" => "WH-x", "event_type" => "BILLING.PLAN.CREATED", "resource" => {} })
      end
    end
    assert_response :ok
  end

  private

  def post_webhook(event)
    post "/webhooks/paypal", params: event.to_json, headers: {
      "Content-Type" => "application/json",
      "PAYPAL-AUTH-ALGO" => "SHA256withRSA",
      "PAYPAL-CERT-URL" => "https://api.paypal.com/cert",
      "PAYPAL-TRANSMISSION-ID" => "tid-#{SecureRandom.hex(4)}",
      "PAYPAL-TRANSMISSION-SIG" => "sig",
      "PAYPAL-TRANSMISSION-TIME" => Time.current.iso8601
    }
  end

  def create_purchase(order_id: "ORDER_#{SecureRandom.hex(4)}", pack_id: "single", quantity: 1, price_cents: 19_00)
    PaypalPurchase.create!(
      user: @user,
      paypal_order_id: order_id,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @user.solana_address,
      status: "pending"
    )
  end

  def capture_completed_event(purchase:, amount: nil, capture_id: "CAP_#{SecureRandom.hex(4)}",
                              event_type: "PAYMENT.CAPTURE.COMPLETED", status: "COMPLETED", custom_id: nil)
    amount ||= purchase ? format("%.2f", purchase.price_cents / 100.0) : "19.00"
    custom_id ||= purchase ? "paypal_purchase:#{purchase.id}" : "paypal_purchase:0"
    {
      "id" => "WH-#{SecureRandom.hex(4)}",
      "event_type" => event_type,
      "resource" => {
        "id" => capture_id,
        "status" => status,
        "amount" => { "currency_code" => "USD", "value" => amount },
        "custom_id" => custom_id,
        "invoice_id" => purchase&.slug,
        "supplementary_data" => { "related_ids" => { "order_id" => purchase&.paypal_order_id } }
      }
    }
  end

  def order_approved_event(order_id:)
    {
      "id" => "WH-#{SecureRandom.hex(4)}",
      "event_type" => "CHECKOUT.ORDER.APPROVED",
      "resource" => { "id" => order_id, "status" => "APPROVED" }
    }
  end
end
