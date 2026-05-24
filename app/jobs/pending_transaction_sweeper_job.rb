# Expires stale pending/submitted entry-flow PendingTransactions.
#
# Phase 2 recovery (ContestsController#recover_pending_entry) auto-resolves
# stranded entries when the user returns to the contest page. Users who
# never return leave their PTs in pending/submitted forever. This job
# flips entry-flow PTs older than STALE_AFTER to failed so admin tools
# (and PendingTransaction.pending.count) reflect what's genuinely active.
#
# Scoped to tx_type=enter_contest_direct on purpose — treasury PTs
# (settle / withdraw) have their own admin lifecycle and should not be
# expired by this sweeper.
class PendingTransactionSweeperJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 1.hour
  ENTRY_FLOW_TX_TYPES = %w[enter_contest_direct].freeze

  def perform(stale_after_hours: nil)
    cutoff = (stale_after_hours&.to_f&.hours || STALE_AFTER).ago
    scope = PendingTransaction.where(status: %w[pending submitted],
                                     tx_type: ENTRY_FLOW_TX_TYPES)
                              .where("created_at < ?", cutoff)
    expired = scope.update_all(status: "failed", updated_at: Time.current)
    Rails.logger.info "[pending_transaction_sweeper] expired=#{expired} cutoff=#{cutoff.iso8601}"
    expired
  end
end
