# Enqueued by Contests::WinnerNotifier.call once a contest's on-chain
# settlement lands (settle_contest PendingTransaction confirmed →
# contest.onchain_settled true). Sends one winnings email per winning entry
# via ContestMailer#winnings.
#
# Idempotency lives in TWO places (belt + suspenders):
#   1. The caller (WinnerNotifier) only enqueues entries with
#      winner_notified_at IS NULL.
#   2. This job re-checks the flag inside the job (a Sidekiq retry or a
#      double-enqueue races the DB, not the in-memory list) and stamps
#      winner_notified_at in the SAME transaction as the deliver, so a
#      second run for the same entry is a no-op.
#
# Wallet-only winners (no email) are filtered out by the caller; this job
# also guards defensively in case an entry's user loses its email between
# enqueue and perform.
class WinnerNotificationJob < ApplicationJob
  queue_as :default

  def perform(entry_id)
    entry = Entry.find_by(id: entry_id)
    return unless entry
    return if entry.winner_notified_at.present?       # already notified — idempotent no-op
    return unless entry.payout_cents.to_i.positive?   # not a winner
    return if entry.user&.email.blank?                # wallet-only — skip silently

    Entry.transaction do
      # Re-load with a row lock so two concurrent jobs can't both pass the
      # winner_notified_at guard and double-send.
      locked = Entry.lock.find(entry.id)
      return if locked.winner_notified_at.present?

      EmailDelivery.deliver(ContestMailer, :winnings, locked, to: locked.user.email, user: locked.user)
      locked.update_column(:winner_notified_at, Time.current)
    end
  end
end
