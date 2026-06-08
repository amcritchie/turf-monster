module Entries
  # Out-of-band self-heal for a stranded on-chain-paid entry. Enqueued by
  # ContestsController#enter when a post-broadcast Entry#confirm! fails (the
  # token/USDC is already spent on-chain, so the entry must converge to active
  # rather than sit in `cart`). Idempotent — see Entries::OnchainReconciler;
  # re-running never double-enters or double-charges.
  #
  # Given an entry_id, heals that one entry. With no id, sweeps every eligible
  # open contest (the scheduled / operator path, mirroring the rake task).
  class OnchainReconcileJob < ApplicationJob
    queue_as :default

    def perform(entry_id = nil)
      if entry_id
        entry = Entry.find_by(id: entry_id)
        return Rails.logger.info("[reconcile][job] entry_id=#{entry_id} gone — nothing to do") unless entry
        outcome = Entries::OnchainReconciler.reconcile_entry(entry)
        Rails.logger.info("[reconcile][job] entry_id=#{entry_id} -> #{outcome}")
      else
        stats = Entries::OnchainReconciler.run
        Rails.logger.info("[reconcile][job] sweep -> #{stats.to_h}")
      end
    end
  end
end
