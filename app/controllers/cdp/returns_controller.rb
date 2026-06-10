module Cdp
  # The redirectUrl landing pages + the local-state poll endpoint:
  #
  #   GET /cdp/onramp/return                      — back from the buy widget
  #   GET /cdp/offramp/return                     — back from the sell widget
  #   GET /cdp/ramp_status/:partner_user_ref      — OUR CdpRampTransaction row
  #                                                 as JSON (page/modal poller)
  #
  # The Coinbase redirect carries NO documented query params — the hit is a
  # UX-only signal, NEVER confirmation (§8). The page identifies the session
  # by the viewer's most recent active ramp row of that direction; the poll
  # jobs (Cdp::OnrampPollJob / Cdp::OfframpPollJob) are what verify against
  # the Transaction Status API.
  class ReturnsController < BaseController
    def onramp
      handle_return(:onramp, OnrampPollJob)
    end

    def offramp
      handle_return(:offramp, OfframpPollJob)
    end

    # Local CdpRampTransaction state for the return page / modal poller. Reads
    # OUR row only — never proxies CDP (the poll jobs own that). Scoped to the
    # viewer so one user can't watch another's ramp.
    def status
      ramp = current_user.cdp_ramp_transactions.find_by(partner_user_ref: params[:partner_user_ref])
      return render json: { error: "not found" }, status: :not_found unless ramp

      confirm_onramp_by_balance(ramp)
      render json: status_payload(ramp)
    end

    private

    # Balance-anchored purchase confirmation, half 2 (the modal's 5s poll
    # drives this): a buy is done when the destination wallet's USDC exceeds
    # the at-mint baseline snapshot. Coinbase's transactions API does not
    # attribute guest-checkout buys to partnerUserRef (observed 2026-06-10),
    # so the wallet is the signal that always fires; the CDP poll jobs keep
    # running for audit enrichment. Fresh RPC read per poll, deliberately
    # uncached — one open modal is one read per 5s and trial mode caps
    # volume. mark_success! is forward-only, so a racing CDP poll job can
    # never be downgraded by this path (nor vice versa).
    def confirm_onramp_by_balance(ramp)
      return unless ramp.onramp? && !ramp.terminal?
      baseline = ramp.raw_payload&.dig("baseline_usdc")
      return if baseline.blank?

      current = Solana::Vault.new.fetch_wallet_balances(ramp.wallet_address)[:usdc]
      return if current.nil? || BigDecimal(current.to_s) <= BigDecimal(baseline)

      rescue_and_log(target: ramp, parent: current_user) do
        ramp.update!(raw_payload: ramp.raw_payload.merge(
          "funds_arrived_at" => Time.current.iso8601,
          "confirmed_via"    => "wallet_balance",
          "usdc_after"       => current.to_s
        ))
        ramp.mark_success!
      end
    rescue StandardError => e
      Rails.logger.warn "[cdp] balance confirmation failed for #{ramp.partner_user_ref}: #{e.message}"
    end

    def handle_return(direction, job_class)
      @ramp = current_user.cdp_ramp_transactions.active.where(direction: direction).recent.first
      unless @ramp
        noun = direction == :onramp ? "purchase" : "cash-out"
        return redirect_to wallet_path, alert: "We couldn't find a pending Coinbase #{noun} session."
      end

      rescue_and_log(target: @ramp, parent: current_user) do
        @ramp.mark_returned!
        # Always (re-)schedule on a return hit: poll loops are idempotent and
        # self-terminating (terminal status / deadline+grace), so a revisit
        # after a dyno restart revives a dead loop instead of stranding the row.
        job_class.schedule_initial(@ramp)
      end
      render :show
    rescue StandardError
      redirect_to wallet_path, alert: "Something went wrong checking your Coinbase session. Please refresh."
    end

    def status_payload(ramp)
      {
        partner_user_ref:     ramp.partner_user_ref,
        direction:            ramp.direction,
        wallet_mode:          ramp.wallet_mode,
        status:               ramp.status,
        cdp_status:           ramp.cdp_status,
        terminal:             ramp.terminal?,
        tx_hash:              ramp.tx_hash,
        to_address:           ramp.to_address,
        sell_amount:          ramp.sell_amount&.to_s("F"),
        sell_amount_currency: ramp.sell_amount_currency,
        cashout_deadline_at:  ramp.cashout_deadline_at&.iso8601,
        sent_signature:       ramp.sent_signature,
        returned_at:          ramp.returned_at&.iso8601
      }
    end
  end
end
