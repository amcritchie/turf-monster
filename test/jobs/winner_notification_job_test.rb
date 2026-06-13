require "test_helper"

class WinnerNotificationJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @contest = contests(:one)
    @entry = @contest.entries.create!(
      user: users(:alex),
      status: "complete",
      rank: 1,
      payout_cents: 4500,
      score: 1.0
    )
  end

  test "delivers the winnings email and stamps winner_notified_at" do
    assert_difference "EmailDelivery.count", 1 do
      WinnerNotificationJob.perform_now(@entry.id)
    end
    assert_not_nil @entry.reload.winner_notified_at
  end

  test "is a no-op when already notified (idempotent)" do
    @entry.update_column(:winner_notified_at, Time.current)

    assert_no_difference "EmailDelivery.count" do
      WinnerNotificationJob.perform_now(@entry.id)
    end
  end

  test "skips wallet-only winners with no email" do
    wallet_user = User.create!(
      name: "Wallet Winner",
      web3_solana_address: "WaLLetJob111111111111111111111111111111111",
      session_token: SecureRandom.hex(32)
    )
    entry = @contest.entries.create!(
      user: wallet_user, status: "complete", rank: 1, payout_cents: 7500, score: 1.0
    )

    assert_no_difference "EmailDelivery.count" do
      WinnerNotificationJob.perform_now(entry.id)
    end
    assert_nil entry.reload.winner_notified_at
  end

  test "skips non-winning entries" do
    @entry.update_column(:payout_cents, 0)

    assert_no_difference "EmailDelivery.count" do
      WinnerNotificationJob.perform_now(@entry.id)
    end
  end
end
