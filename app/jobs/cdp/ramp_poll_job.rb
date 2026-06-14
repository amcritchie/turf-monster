module Cdp
  # Shared skeleton for the CDP Transaction Status pollers
  # (docs/CDP_RAMP_INTEGRATION.md §11). Subclasses provide:
  #   api_path(ramp) — the per-direction status endpoint path
  #   apply(ramp, tx) — direction-specific status handling
  #
  # Cadence: each run re-enqueues ITSELF via set(wait:) on the
  # 10s → 30s → 1m → 2m → 5m backoff (then 5m repeating). The loop is STARTED
  # at session-mint time by Cdp::RampSessionsController (schedule_from_mint,
  # first poll after MINT_POLL_DELAY — "avoid polling immediately after
  # generating the URL") and (re-)scheduled by Cdp::ReturnsController on the
  # return-page hit. Reconciliation must never hinge on the redirect alone:
  # an un-allowlisted domain or a closed Coinbase tab silently drops it while
  # the transaction still completes (spec Risks — "broken by design"), and
  # offramp to_address discovery MUST run or the 30-minute cashout window
  # lapses with no send. The loop stops at a terminal local status or at
  # deadline + grace.
  #
  # Faults: a Cdp::Client::Error (timeout / 5xx / 429) is captured to ErrorLog
  # and the cadence CONTINUES — a flaky CDP response must not kill the loop;
  # the deadline bounds total attempts. Any other error is captured and
  # re-raised so ActiveJob/Sidekiq retry semantics still apply. Every poll is
  # idempotent: state is upserted by coinbase_transaction_id and transitions
  # go through the guarded CdpRampTransaction mark_*! methods, so overlapping
  # loops (e.g. a return-page revisit re-scheduling) converge instead of
  # double-applying.
  class RampPollJob < ApplicationJob
    queue_as :default

    POLL_DELAYS = [10.seconds, 30.seconds, 1.minute, 2.minutes, 5.minutes].freeze
    # Onramp has no documented completion deadline — poll a bounded window
    # from the return-page hit. Offramp gets the precise cashout_deadline_at
    # (CDP created_at + 30min) once the CDP transaction appears.
    POLL_WINDOW = 30.minutes
    GRACE       = 10.minutes
    # page_size DEFAULTS TO 1 server-side — always pass it (§11).
    PAGE_SIZE   = 50
    # First poll delay when scheduled at session-mint time: long enough to
    # satisfy "avoid polling immediately after generating the URL" (the user
    # is still inside the hosted widget), short enough that offramp
    # to_address discovery starts well inside the 30-minute cashout window.
    MINT_POLL_DELAY = 1.minute

    # Entry point used by Cdp::ReturnsController (return-page hit) and
    # Cdp::OfframpSendsController (Phantom `sent` nudge).
    def self.schedule_initial(ramp)
      set(wait: POLL_DELAYS.first).perform_later(ramp_id: ramp.id, attempt: 0)
    end

    # Entry point used by Cdp::RampSessionsController at session-mint time —
    # the loop must start even if the return redirect never fires (closed
    # tab, allowlist regression). Idempotent + deadline-bounded, so a later
    # return-hit schedule_initial converges with this loop instead of
    # double-applying.
    def self.schedule_from_mint(ramp)
      set(wait: MINT_POLL_DELAY).perform_later(ramp_id: ramp.id, attempt: 0)
    end

    def perform(ramp_id:, attempt: 0)
      ramp = CdpRampTransaction.find_by(id: ramp_id)
      unless ramp
        Rails.logger.info("[cdp][poll] ramp_id=#{ramp_id} gone — stopping")
        return
      end
      if ramp.terminal?
        Rails.logger.info("[cdp][poll] #{ramp.partner_user_ref} already terminal (#{ramp.status}) — stopping")
        return
      end
      if past_deadline?(ramp)
        handle_deadline_lapse(ramp)
        return
      end

      begin
        poll(ramp)
      rescue Cdp::Client::Error => e
        capture_with_context(e, ramp)
      end

      if ramp.terminal?
        Rails.logger.info("[cdp][poll] #{ramp.partner_user_ref} reached #{ramp.status} — stopping")
        return
      end
      requeue(ramp, attempt)
    rescue StandardError => e
      # Job-level fault (bug, DB error) — log with context, then re-raise so
      # Sidekiq retries. Cdp::Client::Error never reaches here (rescued above).
      capture_with_context(e, ramp)
      raise
    end

    private

    # ── Subclass contract ────────────────────────────────────────────────────

    def api_path(_ramp)
      raise NotImplementedError, "#{self.class} must implement #api_path"
    end

    def apply(_ramp, _tx)
      raise NotImplementedError, "#{self.class} must implement #apply"
    end

    # ── Shared poll machinery ────────────────────────────────────────────────

    def client
      @client ||= Cdp::Client.new
    end

    def poll(ramp)
      Current.user = ramp.user
      Current.outbound_source = ramp

      response = client.get(api_path(ramp), { page_size: PAGE_SIZE })
      tx = newest_transaction(response)
      if tx.nil?
        Rails.logger.info("[cdp][poll] #{ramp.partner_user_ref} no CDP transaction yet")
        return
      end
      apply(ramp, tx)
    end

    # transactions[] is reverse chronological; with our per-session
    # partner_user_ref the first row is ours (§11/[^13]). Defensive "data"
    # unwrap mirrors Cdp::Catalog (spec open question 8).
    def newest_transaction(response)
      payload = response.is_a?(Hash) ? response : {}
      payload = payload["data"] if payload["data"].is_a?(Hash)
      transactions = payload["transactions"]
      return nil unless transactions.is_a?(Array)

      transactions.find { |tx| tx.is_a?(Hash) }
    end

    # Idempotent upsert keyed on coinbase_transaction_id. Returns false (and
    # skips the row) when it carries a DIFFERENT CDP transaction id than the
    # one already bound — shouldn't happen with per-session refs, so log it
    # rather than silently rebinding the row to another transaction.
    def upsert_common(ramp, tx)
      tx_id = tx["transaction_id"].presence || tx["id"].presence
      if tx_id.present? && ramp.coinbase_transaction_id.present? && ramp.coinbase_transaction_id != tx_id
        Rails.logger.warn("[cdp][poll] #{ramp.partner_user_ref} transaction_id mismatch " \
                          "have=#{ramp.coinbase_transaction_id} got=#{tx_id} — ignoring row")
        return false
      end

      ramp.coinbase_transaction_id = tx_id if tx_id.present?
      # Raw CDP status stored VERBATIM — the enum conflicts across doc pages,
      # so unknown values must survive untouched for triage.
      ramp.cdp_status     = tx["status"].to_s if tx["status"].present?
      ramp.tx_hash        = tx["tx_hash"].presence || ramp.tx_hash
      ramp.payment_method = tx["payment_method"].presence || ramp.payment_method
      ramp.raw_payload    = tx
      ramp.save!
      true
    end

    def requeue(ramp, attempt)
      delay = POLL_DELAYS[attempt + 1] || POLL_DELAYS.last
      Rails.logger.info("[cdp][poll] #{ramp.partner_user_ref} next poll in #{delay.inspect} (attempt=#{attempt + 1})")
      self.class.set(wait: delay).perform_later(ramp_id: ramp.id, attempt: attempt + 1)
    end

    def past_deadline?(ramp)
      Time.current > poll_deadline(ramp) + GRACE
    end

    def poll_deadline(ramp)
      ramp.cashout_deadline_at || ((ramp.returned_at || ramp.created_at) + POLL_WINDOW)
    end

    def handle_deadline_lapse(ramp)
      if ramp.pre_cdp? && ramp.coinbase_transaction_id.blank?
        # Nothing ever materialized at CDP — the hosted session lapsed.
        ramp.mark_expired!
        Rails.logger.info("[cdp][poll] #{ramp.partner_user_ref} deadline+grace passed with no CDP transaction — expired")
      else
        # A CDP transaction exists (or our lifecycle moved past pre-CDP) —
        # funds may still be in flight. Onramp rows never leave `returned`
        # (a pre-CDP status) while the buy is IN_PROGRESS, and a slow ACH /
        # card-review buy can easily outlast the poll window — marking it
        # expired would render the buy-failed card while the user's USDC is
        # still on its way. Never auto-expire a row CDP knows about; stop
        # polling and leave settlement to the phase-2 webhooks/sweep (a late
        # offramp send goes FAILED on CDP's side, [^11]).
        Rails.logger.warn("[cdp][poll] #{ramp.partner_user_ref} deadline+grace passed in #{ramp.status} " \
                          "(cdp tx=#{ramp.coinbase_transaction_id || 'none'}) — stopping poll, leaving status for the sweep")
      end
    end

    # Job-level ErrorLog discipline (mcritchie-studio/docs/agents/modules/backend-discipline.md):
    # nothing escapes unlogged; target = the ramp row, parent = its user.
    def capture_with_context(exception, ramp)
      error_log = ErrorLog.capture!(exception)
      if ramp
        error_log.target = ramp
        error_log.target_name = ramp.slug
        if ramp.user
          error_log.parent = ramp.user
          error_log.parent_name = ramp.user.slug
        end
        error_log.save!
      end
      Rails.logger.error("[cdp][poll][error] ramp=#{ramp&.partner_user_ref} #{exception.class}: #{exception.message}")
    rescue StandardError => e
      Rails.logger.error("[cdp][poll][error] ErrorLog capture failed: #{e.class}: #{e.message}")
    end
  end
end
