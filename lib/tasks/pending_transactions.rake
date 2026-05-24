# Stale PendingTransaction cleanup.
#
# Phase 2 of the entry-flow PT trail (audit 2026-05-24) auto-recovers
# stranded entries on contest load — but only if the user comes back to
# the contest page. PTs created by users who never return accumulate as
# pending/submitted rows indefinitely. This task flips PTs older than a
# threshold (default 1 hour) to failed so admin tooling has a clean
# signal of what actually needs investigation.
#
# Defaults are conservative: we don't touch the treasury PTs (tx_type
# settle/withdraw — those have a different lifecycle and admin tools).
# Only entry-flow PTs (enter_contest_direct) get cleaned.
#
#   bin/rails pending_transactions:expire_stale
#   bin/rails pending_transactions:expire_stale[2]   # 2-hour threshold
namespace :pending_transactions do
  desc "Flip pending/submitted entry-flow PTs older than N hours (default 1) to failed"
  task :expire_stale, [:hours] => :environment do |_t, args|
    hours = (args[:hours] || "1").to_f
    cutoff = hours.hours.ago
    scope = PendingTransaction.where(status: %w[pending submitted],
                                     tx_type: "enter_contest_direct")
                              .where("created_at < ?", cutoff)

    total = scope.count
    if total.zero?
      puts "No stale entry-flow PTs older than #{hours}h."
      next
    end

    puts "Expiring #{total} stale entry-flow PT#{total == 1 ? "" : "s"} (created before #{cutoff})…"
    expired = scope.update_all(status: "failed", updated_at: Time.current)
    puts "✓ flipped #{expired} → failed"
  end
end
