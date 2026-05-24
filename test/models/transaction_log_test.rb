require "test_helper"

# LW7 (Stage 3 audit): TransactionLog is the audit log for every money-moving
# event. Two unique partial indexes — stripe_session_id and moonpay_tx_id —
# are the load-bearing defense against double-crediting on webhook retry.
class TransactionLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
  end

  test "record! creates a row with the canonical field shape" do
    log = TransactionLog.record!(
      user: @user, type: "deposit", amount_cents: 5_00,
      direction: "credit", description: "test"
    )
    assert log.persisted?
    assert_equal "deposit", log.transaction_type
    assert_equal 5_00, log.amount_cents
    assert_equal "credit", log.direction
    assert_equal "completed", log.status
  end

  test "stripe_session_id unique partial index catches a duplicate webhook insert" do
    sid = "cs_test_dup_#{SecureRandom.hex(4)}"
    TransactionLog.record!(user: @user, type: "token_purchase", amount_cents: 19_00, direction: "credit", stripe_session_id: sid)

    err = assert_raises(ActiveRecord::RecordNotUnique) do
      TransactionLog.record!(user: @user, type: "token_purchase", amount_cents: 19_00, direction: "credit", stripe_session_id: sid)
    end
    assert_match(/index_transaction_logs_on_stripe_session_id_unique/, err.message)
  end

  test "moonpay_tx_id unique partial index catches a duplicate webhook insert" do
    tx_id = "moonpay_dup_#{SecureRandom.hex(4)}"
    TransactionLog.record!(user: @user, type: "deposit", amount_cents: 25_00, direction: "credit", moonpay_tx_id: tx_id)

    err = assert_raises(ActiveRecord::RecordNotUnique) do
      TransactionLog.record!(user: @user, type: "deposit", amount_cents: 25_00, direction: "credit", moonpay_tx_id: tx_id)
    end
    assert_match(/index_transaction_logs_on_moonpay_tx_id_unique/, err.message)
  end

  test "stripe_session_id partial WHERE — many rows with NULL session_id coexist" do
    log1 = TransactionLog.record!(user: @user, type: "payout", amount_cents: 1_00, direction: "credit")
    log2 = TransactionLog.record!(user: @user, type: "payout", amount_cents: 1_00, direction: "credit")
    assert log1.persisted?
    assert log2.persisted?
    assert_nil log1.stripe_session_id
    assert_nil log2.stripe_session_id
  end

  test "moonpay_tx_id partial WHERE — many rows with NULL moonpay_tx_id coexist" do
    log1 = TransactionLog.record!(user: @user, type: "entry_fee", amount_cents: 19_00, direction: "debit")
    log2 = TransactionLog.record!(user: @user, type: "entry_fee", amount_cents: 19_00, direction: "debit")
    assert log1.persisted?
    assert log2.persisted?
  end
end
