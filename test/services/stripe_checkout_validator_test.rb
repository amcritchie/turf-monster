require "test_helper"
require "minitest/mock"
require "ostruct"

class StripeCheckoutValidatorTest < ActiveSupport::TestCase
  setup do
    @alex = users(:alex)
  end

  def session_double(overrides = {})
    defaults = {
      id: "cs_test_validator",
      payment_status: "paid",
      livemode: false,
      amount_total: 1900,
      metadata: { "kind" => "tokens", "quantity" => "1", "user_id" => @alex.id.to_s, "wallet_address" => "TestWallet" }
    }
    OpenStruct.new(defaults.merge(overrides))
  end

  test "ok on a paid sandbox session with matching amount + kind" do
    Stripe::Checkout::Session.stub :retrieve, session_double do
      result = StripeCheckoutValidator.new("cs_test_validator", kind: "tokens").call
      assert result.ok?
    end
  end

  test "fails when TransactionLog already records the session (idempotent re-receipt)" do
    # OPSEC-022: idempotency now keyed on the dedicated stripe_session_id
    # column (DB unique partial index), not metadata JSONB.
    TransactionLog.record!(user: @alex, type: "token_purchase", amount_cents: 19_00, direction: "credit",
                           stripe_session_id: "cs_dup")
    result = StripeCheckoutValidator.new("cs_dup", kind: "tokens").call
    assert_not result.ok?
    assert_equal :already_processed, result.reason
  end

  test "fails when payment_status is not paid" do
    Stripe::Checkout::Session.stub :retrieve, session_double(payment_status: "unpaid") do
      result = StripeCheckoutValidator.new("cs_unpaid", kind: "tokens").call
      assert_equal :not_paid, result.reason
    end
  end

  test "fails when amount_total doesn't match the expected pack price" do
    Stripe::Checkout::Session.stub :retrieve, session_double(amount_total: 9999) do
      result = StripeCheckoutValidator.new("cs_wrong_amount", kind: "tokens").call
      assert_equal :amount_mismatch, result.reason
    end
  end

  test "fails when metadata.kind doesn't match expected kind" do
    Stripe::Checkout::Session.stub :retrieve, session_double(metadata: { "kind" => "deposit" }) do
      result = StripeCheckoutValidator.new("cs_wrong_kind", kind: "tokens").call
      assert_equal :kind_mismatch, result.reason
    end
  end

  test "fails when livemode doesn't match Rails.env" do
    # Test env is not production, so livemode: true should fail
    Stripe::Checkout::Session.stub :retrieve, session_double(livemode: true) do
      result = StripeCheckoutValidator.new("cs_live", kind: "tokens").call
      assert_equal :livemode_mismatch, result.reason
    end
  end

  test "fails on unknown pack quantity" do
    Stripe::Checkout::Session.stub :retrieve, session_double(metadata: { "kind" => "tokens", "quantity" => "7", "user_id" => @alex.id.to_s }) do
      result = StripeCheckoutValidator.new("cs_bad_qty", kind: "tokens").call
      assert_equal :amount_mismatch, result.reason
    end
  end

  test "fails when Stripe says session not found" do
    Stripe::Checkout::Session.stub :retrieve, ->(_id) { raise Stripe::InvalidRequestError.new("no such session", "id") } do
      result = StripeCheckoutValidator.new("cs_404", kind: "tokens").call
      assert_equal :session_not_found, result.reason
    end
  end
end
