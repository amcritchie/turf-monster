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

  test "verification receives the RAW request body and the PAYPAL-* headers" do
    client = FakePaypalClient.new
    event = { "id" => "WH-raw", "event_type" => "UNKNOWN.EVENT", "resource" => {} }
    raw = event.to_json
    Paypal::Client.stub :new, client do
      post_webhook_raw(raw)
    end
    assert_response :ok
    assert_equal raw, client.verify_calls.first[:raw_body]
    # The controller→client header handoff is the seam a header-name typo
    # breaks: verify_webhook_signature fails closed on any blank field, so a
    # regression here would 400 EVERY production webhook while a fake that
    # ignores headers stays green. Assert the values actually arrive.
    headers = client.verify_calls.first[:headers]
    assert_equal "SHA256withRSA", headers["PAYPAL-AUTH-ALGO"]
    assert_equal "sig", headers["PAYPAL-TRANSMISSION-SIG"]
    Webhooks::PaypalController::VERIFICATION_HEADERS.each do |name|
      assert headers[name].present?, "#{name} must reach verification non-blank"
    end
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
    # Both sandbox host spellings — PayPal links use api.sandbox.paypal.com
    # AND api-m.sandbox.paypal.com (the client's own SANDBOX_BASE); the
    # original api-only literal let api-m events slip the tell.
    %w[
      https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-1
      https://api-m.sandbox.paypal.com/v1/notifications/webhooks-events/WH-1
    ].each do |href|
      purchase = create_purchase
      event = capture_completed_event(purchase: purchase)
      event["links"] = [{ "href" => href, "rel" => "self" }]
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
      assert_equal "pending", purchase.reload.status, "sandbox event (#{href}) must not fulfill in production"
    end
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

  test "capture completed redelivery re-enqueues only a STALE captured row, never a fresh one" do
    purchase = create_purchase
    purchase.begin_fulfillment!(capture_id: "CAP_X")

    # FRESH captured row → the winner's job is presumed still minting (a trio
    # is several Solana confirms); an immediate re-enqueue would run two
    # concurrent jobs racing the same source_refs (PDA init collision, 0x0,
    # transient captured→failed flip). Redelivery must be a no-op.
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: purchase, capture_id: "CAP_X"))
      end
    end

    # STRANDED: captured past STRANDED_AFTER and still unminted → the original
    # job died; the redelivery is the crash-recovery path and must re-enqueue.
    purchase.update!(captured_at: (Paypal::Fulfillment::STRANDED_AFTER + 1.minute).ago)
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

  test "exactly-once across both paths: capture endpoint + webhook double-enqueue still mints exactly the pack quantity" do
    purchase = create_purchase(order_id: "ORDER_BOTH", pack_id: "trio", quantity: 3, price_cents: 49_00)

    assert_enqueued_jobs 2, only: TokenPurchaseJob do
      # The client's paypal_capture path wins the CAS and enqueues first…
      assert Paypal::Fulfillment.enqueue_mint!(purchase, capture_id: "CAP_BOTH")
      # …then that job dies before minting anything: the row outlives the
      # STRANDED_AFTER window still unminted, and PayPal redelivers the
      # webhook — the stranded-row branch re-enqueues; the job's OPSEC-009
      # idempotency makes the duplicate a no-op.
      purchase.update!(captured_at: (Paypal::Fulfillment::STRANDED_AFTER + 1.minute).ago)
      Paypal::Client.stub :new, FakePaypalClient.new do
        post_webhook(capture_completed_event(purchase: purchase, capture_id: "CAP_BOTH"))
      end
    end

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      perform_enqueued_jobs only: TokenPurchaseJob
    end
    assert_equal 3, vault.mint_calls.length, "double-enqueue must mint exactly quantity tokens, not 2x"
    assert_equal 3, vault.mint_calls.uniq.length
    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length
  end

  test "capture completed for a FROZEN account records the capture but does NOT mint (B4/OPSEC-048)" do
    purchase = create_purchase
    @user.freeze_for_payment_risk!(reason: "prior dispute")
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: purchase, capture_id: "CAP_FRZ"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status, "money moved — forensics keep the capture"
    assert_equal "CAP_FRZ", purchase.capture_id
    assert_equal 0, purchase.tx_signatures.length
  end

  test "capture completed for a payment-risk-flagged account does NOT mint (OPSEC-036)" do
    purchase = create_purchase
    @user.update!(payment_risk_flag: true)
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_no_enqueued_jobs do
        post_webhook(capture_completed_event(purchase: purchase))
      end
    end
    assert_response :ok
    assert_equal "captured", purchase.reload.status
  end

  # ── purchase_for_capture resolution tiers (each exercised ALONE) ───────

  test "capture resolution tier 2: supplementary order_id alone, no custom_id" do
    purchase = create_purchase(order_id: "ORDER_T2")
    event = {
      "id" => "WH-t2", "event_type" => "PAYMENT.CAPTURE.COMPLETED",
      "resource" => {
        "id" => "CAP_T2", "status" => "COMPLETED",
        "amount" => { "currency_code" => "USD", "value" => "19.00" },
        "supplementary_data" => { "related_ids" => { "order_id" => "ORDER_T2" } }
      }
    }
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_enqueued_with(job: TokenPurchaseJob) { post_webhook(event) }
    end
    assert_equal "captured", purchase.reload.status
  end

  test "capture resolution tier 3: CREATE-time invoice_id alone, after later saves" do
    purchase = create_purchase(order_id: "ORDER_T3")
    create_time_slug = purchase.slug
    # PayPal echoes the create-time invoice_id forever, while the row gets
    # saved again in the meantime (paypal_order's update!, mark_minted!, …).
    # Regression: Sluggable's per-save re-derive used to drift the slug on
    # every save, making this tier dead code in production.
    purchase.update!(contest_slug: "some-contest")
    assert_equal create_time_slug, purchase.reload.slug, "slug must be immutable after create"

    event = {
      "id" => "WH-t3", "event_type" => "PAYMENT.CAPTURE.COMPLETED",
      "resource" => {
        "id" => "CAP_T3", "status" => "COMPLETED",
        "amount" => { "currency_code" => "USD", "value" => "19.00" },
        "invoice_id" => create_time_slug
      }
    }
    Paypal::Client.stub :new, FakePaypalClient.new do
      assert_enqueued_with(job: TokenPurchaseJob) { post_webhook(event) }
    end
    assert_equal "captured", purchase.reload.status
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

  test "order approved does NOT capture for a FROZEN account (B4/OPSEC-048 client-gate parity)" do
    purchase = create_purchase(order_id: "ORDER_FROZEN")
    @user.freeze_for_payment_risk!(reason: "prior dispute")
    client = FakePaypalClient.new
    Paypal::Client.stub :new, client do
      assert_no_enqueued_jobs do
        post_webhook(order_approved_event(order_id: "ORDER_FROZEN"))
      end
    end
    assert_response :ok
    assert_equal 0, client.captured_orders.length, "server must not initiate a capture for a frozen account"
    assert_equal "pending", purchase.reload.status
  end

  test "order approved does NOT capture for a payment-risk-flagged account (OPSEC-036)" do
    purchase = create_purchase(order_id: "ORDER_FLAGGED")
    @user.update!(payment_risk_flag: true)
    client = FakePaypalClient.new
    Paypal::Client.stub :new, client do
      assert_no_enqueued_jobs do
        post_webhook(order_approved_event(order_id: "ORDER_FLAGGED"))
      end
    end
    assert_response :ok
    assert_equal 0, client.captured_orders.length
    assert_equal "pending", purchase.reload.status
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
    post_webhook_raw(event.to_json)
  end

  def post_webhook_raw(raw)
    post "/webhooks/paypal", params: raw, headers: {
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
