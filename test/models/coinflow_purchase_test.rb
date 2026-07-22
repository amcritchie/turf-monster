require "test_helper"

class CoinflowPurchaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
  end

  test "valid statuses include captured; invalid rejected" do
    purchase = build_purchase
    CoinflowPurchase::STATUSES.each do |status|
      purchase.status = status
      assert purchase.valid?, "#{status} should be valid"
    end
    purchase.status = "bogus"
    refute purchase.valid?
  end

  test "coinflow_reference is unique but nullable (row exists before it is set)" do
    a = build_purchase(coinflow_reference: nil)
    b = build_purchase(coinflow_reference: nil)
    assert a.save
    assert b.save, "two rows with nil reference must coexist"

    a.update!(coinflow_reference: "coinflow_uniq")
    b.coinflow_reference = "coinflow_uniq"
    refute b.valid?
  end

  test "coinflow_payment_id is unique but nullable (the webhook dedup key)" do
    a = build_purchase
    b = build_purchase
    assert a.save
    assert b.save

    a.update!(coinflow_payment_id: "pay_uniq")
    b.coinflow_payment_id = "pay_uniq"
    refute b.valid?
  end

  test "amounts derive from StripePurchase::PACKS — single source of truth (cents-native)" do
    pack = StripePurchase.pack("single")
    purchase = build_purchase(pack_id: "single", quantity: pack[:quantity], price_cents: pack[:price_cents])
    assert_equal 19_00, purchase.expected_amount_cents
  end

  test "begin_fulfillment! wins exactly once (atomic pending → captured CAS) and stamps the payment id" do
    purchase = build_purchase
    purchase.save!

    assert purchase.begin_fulfillment!(capture_id: "PAY_1"), "first caller wins"
    assert_equal "captured", purchase.status
    assert_equal "PAY_1", purchase.coinflow_payment_id
    assert purchase.captured_at.present?

    refute purchase.begin_fulfillment!(capture_id: "PAY_2"), "second caller loses"
    assert_equal "PAY_1", purchase.reload.coinflow_payment_id, "loser must not overwrite the payment id"
  end

  test "capture_matches? requires USD + exact pack subtotal cents (never the fee-inclusive total)" do
    purchase = build_purchase(pack_id: "single", quantity: 1, price_cents: 19_00)

    good = { "subtotal" => { "cents" => 1900, "currency" => "USD" }, "total" => { "cents" => 2100, "currency" => "USD" } }
    assert purchase.capture_matches?(good), "subtotal 1900 matches even though total (with fees) is 2100"

    refute purchase.capture_matches?(nil)
    refute purchase.capture_matches?({ "subtotal" => { "cents" => 1900, "currency" => "EUR" } })
    refute purchase.capture_matches?({ "subtotal" => { "cents" => 500, "currency" => "USD" } })
    refute purchase.capture_matches?({ "total" => { "cents" => 1900, "currency" => "USD" } }), "must read subtotal, not total"
  end

  test "slug is immutable after create — it IS the coinflow_reference resolved on settlement" do
    purchase = build_purchase(coinflow_reference: nil)
    purchase.save!
    create_time_slug = purchase.slug
    assert create_time_slug.present?
    assert_match(/\Acoinflow_/, create_time_slug)

    # The production sequence: create → set reference = slug in the same request
    # → later saves (capture / mint). Sluggable's per-save re-derive must NOT
    # regenerate the (pure-entropy) slug, or the reference the webhook resolves
    # on would orphan.
    purchase.update!(coinflow_reference: create_time_slug)
    assert_equal create_time_slug, purchase.reload.slug

    purchase.begin_fulfillment!(capture_id: "PAY_S")
    purchase.mark_minted!(["sig_0"])
    assert_equal create_time_slug, purchase.reload.slug

    assert_equal purchase, CoinflowPurchase.for_reference(create_time_slug).first
  end

  test "mark_minted! never overwrites the refunded terminal (refund-during-mint race)" do
    purchase = build_purchase
    purchase.save!
    purchase.begin_fulfillment!(capture_id: "PAY_RM")
    purchase.mark_refunded!(reason: "mid-mint refund")

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

  private

  def build_purchase(**overrides)
    CoinflowPurchase.new({
      user: @user,
      pack_id: "single",
      quantity: 1,
      price_cents: 19_00,
      status: "pending"
    }.merge(overrides))
  end
end
