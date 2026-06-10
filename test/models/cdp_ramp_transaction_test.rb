require "test_helper"

class CdpRampTransactionTest < ActiveSupport::TestCase
  def build_ramp(attrs = {})
    CdpRampTransaction.new({
      user: users(:alex),
      direction: "onramp",
      wallet_address: "So1anaPubkey111",
      wallet_mode: "web3"
    }.merge(attrs))
  end

  test "valid with defaults: initiated status, USDC asset, solana network" do
    ramp = build_ramp
    assert ramp.valid?
    assert ramp.initiated?
    assert_equal "USDC", ramp.asset
    assert_equal "solana", ramp.network
  end

  test "assigns partner_user_ref tm-<user_id>-<id> after create" do
    ramp = build_ramp
    ramp.save!
    assert_equal "tm-#{ramp.user_id}-#{ramp.id}", ramp.partner_user_ref
    assert ramp.partner_user_ref.length < 50
  end

  test "does not clobber a preset partner_user_ref" do
    ramp = build_ramp(partner_user_ref: "custom-ref")
    ramp.save!
    assert_equal "custom-ref", ramp.partner_user_ref
  end

  test "partner_user_ref must be unique and under 50 chars" do
    build_ramp(partner_user_ref: "dup-ref").save!
    dup = build_ramp(partner_user_ref: "dup-ref")
    assert_not dup.valid?
    assert dup.errors[:partner_user_ref].any?

    long = build_ramp(partner_user_ref: "x" * 50)
    assert_not long.valid?
  end

  test "requires direction, wallet_address, and wallet_mode" do
    assert_not build_ramp(wallet_address: nil).valid?
    assert_not build_ramp(wallet_mode: nil).valid?
    assert_raises(ArgumentError) { build_ramp(direction: "sideways") }
  end

  test "status enum covers the local lifecycle and rejects unknown values" do
    ramp = build_ramp
    %w[initiated token_minted returned cdp_created sending sent success failed expired abandoned].each do |status|
      ramp.status = status
      assert ramp.valid?, "expected #{status} to be a valid status"
    end
    assert_raises(ArgumentError) { ramp.status = "locked" }
  end

  test "terminal? is true only for success/failed/expired/abandoned" do
    ramp = build_ramp
    %w[success failed expired abandoned].each do |status|
      ramp.status = status
      assert ramp.terminal?, "#{status} should be terminal"
    end
    %w[initiated token_minted returned cdp_created sending sent].each do |status|
      ramp.status = status
      assert_not ramp.terminal?, "#{status} should not be terminal"
    end
  end

  test "coinbase_transaction_id is unique when present, multiple nils allowed" do
    build_ramp.save!
    build_ramp.save! # second nil coinbase_transaction_id is fine

    build_ramp(coinbase_transaction_id: "cb-tx-1").save!
    dup = build_ramp(coinbase_transaction_id: "cb-tx-1")
    assert_not dup.valid?
  end

  test "sell_amount returns a BigDecimal, never a Float" do
    ramp = build_ramp(direction: "offramp", sell_amount_value: "25.000001", sell_amount_currency: "USDC")
    ramp.save!
    assert_instance_of BigDecimal, ramp.sell_amount
    assert_equal BigDecimal("25.000001"), ramp.sell_amount

    assert_nil build_ramp.sell_amount
  end

  test "wallet_mode enum distinguishes managed (web2) from Phantom (web3)" do
    assert build_ramp(wallet_mode: "web2").wallet_web2?
    assert build_ramp(wallet_mode: "web3").wallet_web3?
  end
end
