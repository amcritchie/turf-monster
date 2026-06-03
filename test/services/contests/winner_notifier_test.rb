require "test_helper"

module Contests
  class WinnerNotifierTest < ActiveJob::TestCase
    setup do
      @contest = contests(:one)
      @contest.entries.destroy_all

      # Wallet-only winner: no email (possible for Phantom-auth users).
      @wallet_only = User.create!(
        name: "Wallet Winner",
        web3_solana_address: "WaLLetWinR1111111111111111111111111111111",
        session_token: SecureRandom.hex(32)
      )
      assert @wallet_only.email.blank?, "precondition: wallet-only user must have no email"

      @winner_with_email = build_entry(users(:alex),   payout_cents: 4500, rank: 1)
      @winner_no_email   = build_entry(@wallet_only,   payout_cents: 7500, rank: 1)
      @loser             = build_entry(users(:jordan), payout_cents: 0,    rank: 3)
    end

    test "enqueues a job only for paying winners that have an email" do
      assert_enqueued_jobs 1, only: WinnerNotificationJob do
        Contests::WinnerNotifier.call(@contest)
      end

      assert_enqueued_with(job: WinnerNotificationJob, args: [@winner_with_email.id])
    end

    test "skips no-email winners and returns a skipped count instead of erroring" do
      result = Contests::WinnerNotifier.call(@contest)

      assert_equal 1, result[:enqueued]
      assert_equal 1, result[:skipped]
    end

    test "does not enqueue for non-winning entries" do
      Contests::WinnerNotifier.call(@contest)

      loser_jobs = enqueued_jobs.select do |job|
        job[:job] == WinnerNotificationJob && job[:args] == [@loser.id]
      end
      assert_empty loser_jobs, "non-winning entry should not be enqueued"
    end

    test "is idempotent — a second call after notification does not re-enqueue" do
      assert_enqueued_jobs 1, only: WinnerNotificationJob do
        Contests::WinnerNotifier.call(@contest)
      end

      # Simulate the job having run for the emailable winner.
      @winner_with_email.update_column(:winner_notified_at, Time.current)

      assert_no_enqueued_jobs only: WinnerNotificationJob do
        Contests::WinnerNotifier.call(@contest)
      end
    end

    test "contest#notify_winners! delegates to the notifier" do
      result = nil
      assert_enqueued_jobs 1, only: WinnerNotificationJob do
        result = @contest.notify_winners!
      end
      assert_equal 1, result[:enqueued]
    end

    private

    def build_entry(user, payout_cents:, rank:)
      @contest.entries.create!(
        user: user,
        status: "complete",
        rank: rank,
        payout_cents: payout_cents,
        score: 1.0
      )
    end
  end
end
