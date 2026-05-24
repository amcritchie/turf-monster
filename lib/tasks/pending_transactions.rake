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
    hours = args[:hours] ? args[:hours].to_f : nil
    expired = PendingTransactionSweeperJob.new.perform(stale_after_hours: hours)
    if expired.zero?
      puts "No stale entry-flow PTs to expire."
    else
      puts "✓ flipped #{expired} → failed"
    end
  end
end
