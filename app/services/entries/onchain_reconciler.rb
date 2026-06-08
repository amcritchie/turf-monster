# Converge stranded on-chain-paid entries to `active`.
#
# The managed-wallet / entry-token entry path (ContestsController#enter) does an
# IRREVERSIBLE on-chain consume (enter_contest_with_token / enter_contest),
# durably stamps the resulting signature + Entry PDA onto the cart entry, and
# THEN runs the gate-running Entry#confirm!. If confirm! (or its commit) fails
# after the broadcast, the user is paid + entered on-chain but the Rails row
# stays `cart` — showing "not entered" while the token reads consumed. That is
# the 2026-06-08 incident (entry #133, manually reconciled).
#
# This service heals such rows. Two flavors, both idempotent:
#
#   - FAST path: the cart entry already carries `onchain_tx_signature` (the
#     durable-capture write landed). We just re-run confirm! with the stored
#     proof — no RPC needed.
#   - PROBE path: a LEGACY strand (e.g. #133, stranded before the durable
#     capture shipped) has no proof on the Rails row. We probe the chain for an
#     Entry PDA at the wallet's slots, recover the consume signature from
#     getSignaturesForAddress (oldest err:nil), and confirm! with it.
#
# Idempotency: only `cart` entries are touched; an already-active/complete entry
# is skipped. The unique partial index on entries.onchain_tx_signature (plus the
# explicit pre-check here) guarantees one consume signature can never credit two
# entries, so re-running this never double-enters or double-charges.
module Entries
  class OnchainReconciler
    # Heal a single entry. Returns :reconciled / :skipped / :error.
    def self.reconcile_entry(entry, vault: Solana::Vault.new)
      new(vault: vault).reconcile_entry(entry)
    end

    # Sweep eligible contests (or one). Returns a counts hash.
    def self.run(contest: nil, vault: Solana::Vault.new)
      new(vault: vault).run(contest: contest)
    end

    def initialize(vault: Solana::Vault.new)
      @vault = vault
    end

    def run(contest: nil)
      contests = contest ? [contest] : eligible_contests
      stats = Hash.new(0)
      contests.each do |c|
        next unless eligible?(c)
        c.entries.where(status: :cart).find_each do |entry|
          stats[reconcile_entry(entry)] += 1
        end
      end
      Rails.logger.info(
        "[reconcile][sweep] contests=#{contests.size} " \
        "reconciled=#{stats[:reconciled]} skipped=#{stats[:skipped]} errors=#{stats[:error]}"
      )
      stats
    end

    def reconcile_entry(entry)
      return :skipped if entry.nil?
      entry.reload
      return :skipped unless entry.cart?

      contest = entry.contest
      return :skipped unless eligible?(contest)

      wallet = entry.user&.solana_address
      return :skipped if wallet.blank?

      sig = entry.onchain_tx_signature.presence
      pda = entry.onchain_entry_id.presence

      if sig.nil?
        # Legacy strand — no proof on the Rails row. Ask the chain.
        pda, sig = find_onchain_entry(contest, wallet, entry)
        return :skipped if sig.nil?
      end

      # Idempotency backstop: never credit a signature already bound to another
      # entry (the DB unique index enforces this too — this gives a clean skip).
      return :skipped if Entry.where.not(id: entry.id).exists?(onchain_tx_signature: sig)

      entry.confirm!(tx_signature: sig, onchain_entry_id: pda)
      Rails.logger.info(
        "[reconcile][healed] entry_id=#{entry.id} contest=#{contest.slug} " \
        "user_id=#{entry.user_id} tx=#{sig.to_s.first(8)}..."
      )
      begin
        Message.announce_join!(contest: contest, user: entry.user)
      rescue StandardError
        # Chat announcement is best-effort — never fail a heal on it.
      end
      :reconciled
    rescue StandardError => e
      # Attach which entry/contest failed to heal so the ErrorLog reads as
      # "entry-<id> in <contest>" rather than a context-free backtrace. `contest`
      # is nil if the fault preceded its assignment (e.g. an entry.reload race).
      error_log = ErrorLog.capture!(e)
      if entry
        error_log.target = entry
        error_log.target_name = entry.slug
      end
      if contest
        error_log.parent = contest
        error_log.parent_name = contest.slug
      end
      error_log.save!
      Rails.logger.error("[reconcile][error] entry_id=#{entry&.id} #{e.class}: #{e.message}")
      :error
    end

    private

    def eligible_contests
      Contest.where(status: :open).select { |c| eligible?(c) }
    end

    # Limit to contests where an on-chain consume genuinely could have stranded
    # an entry: backed by a Contest PDA AND charging a fee.
    def eligible?(contest)
      contest&.onchain? && contest.entry_fee_cents.to_i.positive?
    end

    # Probe the chain for the wallet's Entry PDA in this contest and recover the
    # consume signature. Prefers the entry's already-assigned slot; otherwise
    # scans 0...max_entries_per_user. Skips a slot already claimed by another of
    # this user's live entries. Returns [entry_pda_b58, signature] or [nil, nil].
    def find_onchain_entry(contest, wallet, entry)
      slots = entry.entry_number ? [entry.entry_number] : (0...contest.max_entries_per_user).to_a
      slots.each do |n|
        pda_b58 = Solana::Keypair.encode_base58(@vault.entry_pda(contest.slug, wallet, n).first)
        next unless onchain_account_exists?(pda_b58)
        next if contest.entries.where(user_id: entry.user_id, onchain_entry_id: pda_b58)
                       .where.not(id: entry.id).exists?
        sig = oldest_success_signature(pda_b58)
        return [pda_b58, sig] if sig
      end
      [nil, nil]
    end

    # Resilient existence check — mainnet RPC rate-limits on bursts, so a single
    # transient error shouldn't read as "PDA absent" and silently skip a paid
    # entry. One brief retry, then treat as absent.
    def onchain_account_exists?(pda_b58)
      attempts = 0
      begin
        attempts += 1
        info = @vault.client.get_account_info(pda_b58)
        !!(info && info["value"])
      rescue StandardError => e
        if attempts < 2
          sleep(0.25)
          retry
        end
        Rails.logger.warn("[reconcile][rpc] get_account_info failed pda=#{pda_b58} #{e.message}")
        false
      end
    end

    # The Entry PDA's first successful signature is the enter_contest(_with_token)
    # that created it (and consumed the token). getSignaturesForAddress returns
    # newest-first, so reverse and take the oldest err:nil entry.
    def oldest_success_signature(pda_b58)
      result = @vault.client.send(:call, "getSignaturesForAddress", [pda_b58, { "limit" => 20 }])
      return nil if result.blank?
      hit = result.reverse.find { |s| s && s["err"].nil? }
      hit && hit["signature"]
    rescue StandardError => e
      Rails.logger.warn("[reconcile][rpc] getSignaturesForAddress failed pda=#{pda_b58} #{e.message}")
      nil
    end
  end
end
