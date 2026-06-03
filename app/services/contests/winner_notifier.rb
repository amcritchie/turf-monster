module Contests
  # Selects a settled contest's winning entries (payout_cents > 0) and
  # enqueues a winnings email for each winner that has an email address.
  #
  # Trigger: Admin::PendingTransactionsController#confirm calls this once a
  # settle_contest PendingTransaction is confirmed and the contest's
  # onchain_settled flag flips true — so winners are only notified AFTER the
  # payout actually lands on-chain, not at grade time.
  #
  # Standalone-callable: `Contests::WinnerNotifier.call(contest)` can be run
  # from the console to (re-)notify an already-settled contest's winners
  # (e.g. test8 / juniper-berries). Safe to call twice.
  #
  # Idempotency: only entries with winner_notified_at IS NULL are enqueued,
  # and WinnerNotificationJob re-checks + stamps that flag under a row lock,
  # so a double-call (or a retried job) never double-sends.
  #
  # No-email winners (wallet-only users) are SKIPPED + logged, not errored —
  # a contest that mixes web2 and web3 winners still notifies everyone it can.
  class WinnerNotifier
    def self.call(contest)
      new(contest).call
    end

    def initialize(contest)
      @contest = contest
    end

    def call
      enqueued = 0
      skipped  = 0

      winning_entries.find_each do |entry|
        if entry.user&.email.blank?
          skipped += 1
          Rails.logger.info(
            "[winner-notify][skip] contest=#{@contest.slug} entry=#{entry.slug} " \
            "reason=no_email user=#{entry.user&.slug || 'nil'}"
          )
          next
        end

        WinnerNotificationJob.perform_later(entry.id)
        enqueued += 1
      end

      Rails.logger.info(
        "[winner-notify][done] contest=#{@contest.slug} enqueued=#{enqueued} skipped=#{skipped}"
      )

      { enqueued: enqueued, skipped: skipped }
    end

    private

    # Winners = completed, paying entries not yet notified. The
    # winner_notified_at gate is what makes a repeat call idempotent at the
    # selection layer (the job re-checks under a lock for the race).
    def winning_entries
      @contest.entries
              .complete
              .where("payout_cents > 0")
              .where(winner_notified_at: nil)
              .includes(:user)
    end
  end
end
