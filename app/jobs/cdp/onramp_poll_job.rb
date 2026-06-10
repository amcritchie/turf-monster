module Cdp
  # Polls GET /onramp/v1/buy/user/{partner_user_ref}/transactions (§11/[^14])
  # until the buy reaches a terminal status.
  #
  # Documented statuses: IN_PROGRESS | SUCCESS | FAILED. Unknown values are
  # stored verbatim in cdp_status and polling continues (defensive — the
  # status enums conflict across CDP doc pages).
  class OnrampPollJob < RampPollJob
    STATUS_IN_PROGRESS = "ONRAMP_TRANSACTION_STATUS_IN_PROGRESS".freeze
    STATUS_SUCCESS     = "ONRAMP_TRANSACTION_STATUS_SUCCESS".freeze
    STATUS_FAILED      = "ONRAMP_TRANSACTION_STATUS_FAILED".freeze

    private

    def api_path(ramp)
      "/onramp/v1/buy/user/#{ramp.partner_user_ref}/transactions"
    end

    def apply(ramp, tx)
      return unless upsert_common(ramp, tx)

      case tx["status"].to_s
      when STATUS_SUCCESS
        # USDC landed in the user's wallet. The updated row is what the return
        # page / status endpoint reads; the client-side balance refresh
        # (StateFanout register) is the Frontend phase.
        ramp.mark_success!
        Rails.logger.info("[cdp][poll][onramp] #{ramp.partner_user_ref} SUCCESS tx_hash=#{ramp.tx_hash}")
      when STATUS_FAILED
        ramp.mark_failed!
        Rails.logger.info("[cdp][poll][onramp] #{ramp.partner_user_ref} FAILED")
      when STATUS_IN_PROGRESS, ""
        # Keep polling.
      else
        Rails.logger.warn("[cdp][poll][onramp] #{ramp.partner_user_ref} unknown status " \
                          "#{tx['status'].inspect} — continuing (stored verbatim in cdp_status)")
      end
    end
  end
end
