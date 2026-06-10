require "test_helper"

class PaypalPurchaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
  end

  test "valid statuses include captured; invalid rejected" do
    purchase = build_purchase
    PaypalPurchase::STATUSES.each do |status|
      purchase.status = status
      assert purchase.valid?, "#{status} should be valid"
    end
    purchase.status = "bogus"
    refute purchase.valid?
  end

  test "paypal_order_id is unique but nullable (row exists before the order)" do
    a = build_purchase(paypal_order_id: nil)
    b = build_purchase(paypal_order_id: nil)
    assert a.save
    assert b.save, "two rows with nil order id must coexist"

    a.update!(paypal_order_id: "ORDER_UNIQ")
    b.paypal_order_id = "ORDER_UNIQ"
    refute b.valid?
  end

  test "amounts derive from StripePurchase::PACKS — single source of truth" do
    pack = StripePurchase.pack("trio")
    purchase = build_purchase(pack_id: "trio", quantity: pack[:quantity], price_cents: pack[:price_cents])
    assert_equal "49.00", purchase.expected_amount_value
  end

  test "begin_fulfillment! wins exactly once (atomic pending → captured CAS)" do
    purchase = build_purchase(paypal_order_id: "ORDER_CAS")
    purchase.save!

    assert purchase.begin_fulfillment!(capture_id: "CAP_1"), "first caller wins"
    assert_equal "captured", purchase.status
    assert_equal "CAP_1", purchase.capture_id
    assert purchase.captured_at.present?

    refute purchase.begin_fulfillment!(capture_id: "CAP_2"), "second caller loses"
    assert_equal "CAP_1", purchase.reload.capture_id, "loser must not overwrite the capture id"
  end

  test "capture_matches? requires COMPLETED + USD + exact pack amount" do
    purchase = build_purchase(pack_id: "trio", quantity: 3, price_cents: 49_00)

    good = { "status" => "COMPLETED", "amount" => { "currency_code" => "USD", "value" => "49.00" } }
    assert purchase.capture_matches?(good)

    refute purchase.capture_matches?(nil)
    refute purchase.capture_matches?(good.merge("status" => "PENDING"))
    refute purchase.capture_matches?(good.merge("amount" => { "currency_code" => "EUR", "value" => "49.00" }))
    refute purchase.capture_matches?(good.merge("amount" => { "currency_code" => "USD", "value" => "19.00" }))
  end

  test "capture_pending? recognizes an eCheck/review hold — PENDING + USD + exact amount only" do
    purchase = build_purchase(pack_id: "trio", quantity: 3, price_cents: 49_00)

    hold = { "status" => "PENDING", "amount" => { "currency_code" => "USD", "value" => "49.00" } }
    assert purchase.capture_pending?(hold)

    refute purchase.capture_pending?(nil)
    refute purchase.capture_pending?(hold.merge("status" => "COMPLETED")), "completed is capture_matches? territory"
    refute purchase.capture_pending?(hold.merge("status" => "DECLINED"))
    refute purchase.capture_pending?(hold.merge("amount" => { "currency_code" => "USD", "value" => "5.00" }))
    refute purchase.capture_pending?(hold.merge("amount" => { "currency_code" => "EUR", "value" => "49.00" }))
  end

  test "slug is immutable after create — it is the invoice_id PayPal echoes back forever" do
    purchase = build_purchase(paypal_order_id: nil)
    purchase.save!
    create_time_slug = purchase.slug
    assert create_time_slug.present?

    # The exact production sequence: create → send slug to PayPal as
    # invoice_id → update!(paypal_order_id:) in the same request. Sluggable's
    # per-save re-derive used to regenerate the (pure-entropy) slug here,
    # orphaning the invoice_id and killing webhook tier-3 resolution +
    # PayPal-invoice ↔ DB reconciliation.
    purchase.update!(paypal_order_id: "ORDER_SLUG_STABLE")
    assert_equal create_time_slug, purchase.reload.slug

    purchase.begin_fulfillment!(capture_id: "CAP_S")
    purchase.mark_minted!(["sig_0"])
    assert_equal create_time_slug, purchase.reload.slug

    assert_equal purchase, PaypalPurchase.find_by(slug: create_time_slug)
  end

  test "mark_minted! never overwrites the refunded terminal (refund-during-mint race)" do
    purchase = build_purchase
    purchase.save!
    purchase.begin_fulfillment!(capture_id: "CAP_RM")
    purchase.mark_refunded!(reason: "mid-mint refund")

    # The mint job finishing after the refund webhook must not flip the
    # authoritative refund record back to "minted" — but the on-chain mints
    # DID happen, so the signatures still land for forensics.
    purchase.mark_minted!(%w[sig_a])
    purchase.reload
    assert_equal "refunded", purchase.status
    assert_equal %w[sig_a], purchase.tx_signatures
    assert purchase.minted_at.present?
    assert purchase.refunded_at.present?
  end

  test "MintablePurchase parity: mark_minted!, tx_signatures, H8 no-downgrade" do
    purchase = build_purchase
    purchase.save!

    purchase.mark_minted!(%w[sig_a sig_b])
    assert_equal "minted", purchase.status
    assert_equal %w[sig_a sig_b], purchase.tx_signatures
    assert purchase.minted_at.present?

    purchase.mark_failed_unless_minted!
    assert_equal "minted", purchase.reload.status, "H8: never downgrade a minted purchase"
  end

  test "mark_refunded! records reason and timestamp" do
    purchase = build_purchase
    purchase.save!
    purchase.mark_refunded!(reason: "paypal payment.capture.refunded")
    assert_equal "refunded", purchase.status
    assert purchase.refunded_at.present?
    assert_match(/refunded/, purchase.refund_reason)
  end

  private

  def build_purchase(**overrides)
    PaypalPurchase.new({
      user: @user,
      pack_id: "single",
      quantity: 1,
      price_cents: 19_00,
      status: "pending",
      paypal_order_id: "ORDER_#{SecureRandom.hex(4)}"
    }.merge(overrides))
  end
end
