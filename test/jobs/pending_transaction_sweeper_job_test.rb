require "test_helper"

class PendingTransactionSweeperJobTest < ActiveJob::TestCase
  setup do
    @entry = entries(:one)
  end

  test "flips entry-flow PTs older than 1h from pending to failed" do
    old_pending = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "pending", target: @entry, created_at: 2.hours.ago
    )
    old_submitted = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig", target: @entry, created_at: 2.hours.ago
    )
    recent = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "pending", target: @entry, created_at: 5.minutes.ago
    )

    expired = PendingTransactionSweeperJob.perform_now

    assert_equal 2, expired
    assert_equal "failed", old_pending.reload.status
    assert_equal "failed", old_submitted.reload.status
    assert_equal "pending", recent.reload.status
  end

  test "leaves treasury PTs alone even when stale" do
    treasury = PendingTransaction.create!(
      tx_type: "settle", serialized_tx: "stx",
      status: "pending", target: @entry, created_at: 2.days.ago
    )

    PendingTransactionSweeperJob.perform_now

    assert_equal "pending", treasury.reload.status
  end

  test "leaves already-confirmed and failed PTs alone" do
    confirmed = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "confirmed", tx_signature: "sig", target: @entry, created_at: 2.days.ago
    )
    failed = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "failed", target: @entry, created_at: 2.days.ago
    )

    PendingTransactionSweeperJob.perform_now

    assert_equal "confirmed", confirmed.reload.status
    assert_equal "failed",    failed.reload.status
  end

  test "respects stale_after_hours override" do
    old = PendingTransaction.create!(
      tx_type: "enter_contest_direct", serialized_tx: "stx",
      status: "pending", target: @entry, created_at: 30.minutes.ago
    )

    # default 1h → 30min-old not expired
    PendingTransactionSweeperJob.perform_now
    assert_equal "pending", old.reload.status

    # 10min threshold → 30min-old expired
    PendingTransactionSweeperJob.perform_now(stale_after_hours: 0.166)
    assert_equal "failed", old.reload.status
  end
end
