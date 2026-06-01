require "test_helper"

# BL4 (Stage 3 audit): PendingTransaction is the row that backs every 2-of-3
# Squads multisig settlement TX. Bug here = ops can't pay winners.
class PendingTransactionTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
  end

  def build_ptx(**overrides)
    PendingTransaction.new({
      tx_type: "settle_contest",
      serialized_tx: "base64-tx-blob-#{SecureRandom.hex(4)}",
      status: "pending",
      target: @contest,
      initiator_address: "InitAddr",
      metadata: { winners: [{ wallet: "WinnerAddr", amount: 30000 }] }
    }.merge(overrides))
  end

  test "tx_type is required" do
    ptx = build_ptx(tx_type: nil)
    refute ptx.valid?
    assert ptx.errors[:tx_type].any?
  end

  test "serialized_tx is required" do
    ptx = build_ptx(serialized_tx: nil)
    refute ptx.valid?
    assert ptx.errors[:serialized_tx].any?
  end

  test "status must be one of the documented values" do
    %w[pending submitted confirmed expired failed].each do |s|
      assert build_ptx(status: s).valid?, "status=#{s.inspect} should be valid"
    end
    refute build_ptx(status: "bogus").valid?
  end

  test "target is polymorphic and can hold a Contest" do
    ptx = build_ptx; ptx.save!
    assert_equal "Contest", ptx.reload.target_type
    assert_equal @contest.id, ptx.target_id
    assert_equal @contest, ptx.target
  end

  test "target is optional — a multisig op without a target row persists" do
    ptx = build_ptx(target: nil, tx_type: "update_signers")
    assert ptx.save
    assert_nil ptx.reload.target
  end

  test "#pending? and #confirmed? mirror status string" do
    assert build_ptx(status: "pending").pending?
    refute build_ptx(status: "pending").confirmed?
    refute build_ptx(status: "confirmed").pending?
    assert build_ptx(status: "confirmed").confirmed?
  end

  test "scope :pending returns only pending rows" do
    pending_ptx = build_ptx(status: "pending"); pending_ptx.save!
    confirmed   = build_ptx(status: "confirmed"); confirmed.save!

    assert_includes PendingTransaction.pending, pending_ptx
    refute_includes PendingTransaction.pending, confirmed
  end

  test "metadata jsonb survives a save/reload round-trip (winners shape)" do
    winners = [
      { "wallet" => "AlphaAddr", "amount" => 30000 },
      { "wallet" => "BetaAddr",  "amount" => 5000  }
    ]
    ptx = build_ptx(metadata: { "winners" => winners, "contest_slug" => @contest.slug })
    ptx.save!; ptx.reload

    assert_equal winners, ptx.metadata["winners"]
    assert_equal @contest.slug, ptx.metadata["contest_slug"]
  end

  test "#parsed_metadata returns {} when metadata column is blank" do
    ptx = build_ptx; ptx.save!
    ptx.update_column(:metadata, nil)
    assert_equal({}, ptx.reload.parsed_metadata)
  end

  # BL4 regression test for the slug bug fix.
  # Pre-fix every row got slug "ptx-" and the unique index meant only ONE
  # PendingTransaction could exist at a time (treasury blocker).
  test "after_create assigns slug 'ptx-<id>' — multiple rows coexist" do
    ptx1 = build_ptx; ptx1.save!
    ptx2 = build_ptx; ptx2.save!

    assert_match(/\Aptx-\d+\z/, ptx1.slug)
    assert_match(/\Aptx-\d+\z/, ptx2.slug)
    assert_not_equal ptx1.slug, ptx2.slug
  end

  test "to_param returns the slug (per Sluggable)" do
    ptx = build_ptx; ptx.save!
    assert_equal ptx.slug, ptx.to_param
  end

  # Single-use broadcast signatures (Lazarus audit #8 residual). A finalized
  # tx_signature may back at most one PendingTransaction; unbroadcast (nil) rows
  # are unconstrained. Mirrors the entries.onchain_tx_signature guard.
  test "tx_signature is unique among non-null rows; nil is unconstrained" do
    sig = "Sig#{SecureRandom.hex(8)}"
    build_ptx(tx_signature: sig).save!

    dup = build_ptx(tx_signature: sig)
    refute dup.valid?, "a second row with the same tx_signature must be rejected"
    assert dup.errors[:tx_signature].any?

    assert build_ptx(tx_signature: nil).save, "first nil-signature row saves"
    assert build_ptx(tx_signature: nil).save, "second nil-signature row coexists"
  end
end
