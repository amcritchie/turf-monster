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

      render json: status_payload(ramp)
    end

    private

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
