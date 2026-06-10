module Cdp
  # Polls GET /onramp/v1/sell/user/{partner_user_ref}/transactions (§11/[^13])
  # until the sell reaches a terminal status — and performs the §10 DISCOVERY
  # half of the offramp send: the first CDP row carrying to_address gives us
  # the Coinbase-managed address our USDC transfer must target, the amount,
  # and starts the 30-minute cashout window (cashout_deadline_at).
  #
  # The send itself (Cdp::OfframpSendJob — managed-mode server-sign / Phantom
  # client-sign) is the NEXT phase; this job only persists what it will need.
  #
  # API-reference statuses: CREATED | EXPIRED | STARTED | SUCCESS | FAILED
  # (the guide page lists only the last three — handle unknowns defensively).
  class OfframpPollJob < RampPollJob
    STATUS_CREATED = "TRANSACTION_STATUS_CREATED".freeze
    STATUS_STARTED = "TRANSACTION_STATUS_STARTED".freeze
    STATUS_SUCCESS = "TRANSACTION_STATUS_SUCCESS".freeze
    STATUS_FAILED  = "TRANSACTION_STATUS_FAILED".freeze
    STATUS_EXPIRED = "TRANSACTION_STATUS_EXPIRED".freeze

    # "Your app must facilitate this onchain transaction" within 30 minutes of
    # the CDP transaction's creation ([^10]).
    CASHOUT_WINDOW = 30.minutes

    private

    def api_path(ramp)
      "/onramp/v1/sell/user/#{ramp.partner_user_ref}/transactions"
    end

    def apply(ramp, tx)
      return unless upsert_common(ramp, tx)

      # Discovery keys on DATA presence, not just the CREATED status — if our
      # first poll lands after the user already sent (STARTED), the row still
      # carries to_address/sell_amount and the send flow still needs them.
      discover(ramp, tx) if ramp.to_address.blank? && tx["to_address"].present?

      case tx["status"].to_s
      when STATUS_CREATED
        ramp.mark_cdp_created!
      when STATUS_STARTED
        # Coinbase detected the send; settlement pending — keep polling.
      when STATUS_SUCCESS
        ramp.mark_success!
        Rails.logger.info("[cdp][poll][offramp] #{ramp.partner_user_ref} SUCCESS tx_hash=#{ramp.tx_hash}")
      when STATUS_FAILED
        # Includes the late-send case: funds sent after the window land in the
        # user's Coinbase crypto balance but the sell never auto-completes.
        ramp.mark_failed!
        Rails.logger.info("[cdp][poll][offramp] #{ramp.partner_user_ref} FAILED")
      when STATUS_EXPIRED
        ramp.mark_expired!
        Rails.logger.info("[cdp][poll][offramp] #{ramp.partner_user_ref} EXPIRED")
      when ""
        # No status on the row — keep polling.
      else
        Rails.logger.warn("[cdp][poll][offramp] #{ramp.partner_user_ref} unknown status " \
                          "#{tx['status'].inspect} — continuing (stored verbatim in cdp_status)")
      end
    end

    # §10 discovery: persist everything the send flow needs. Idempotent — the
    # to_address guard in apply means this runs once per ramp row; a re-run
    # before to_address stuck (blank in the row) just rewrites the same values.
    def discover(ramp, tx)
      sell_amount = tx["sell_amount"]
      created_at  = parse_time(tx["created_at"] || tx["createdAt"]) || Time.current
      ramp.update!(
        to_address:           tx["to_address"],
        sell_amount_value:    Cdp::Client.money_value(sell_amount),
        sell_amount_currency: sell_amount.is_a?(Hash) ? sell_amount["currency"] : nil,
        network:              tx["network"].presence || ramp.network,
        cashout_deadline_at:  ramp.cashout_deadline_at || (created_at + CASHOUT_WINDOW)
      )
      Rails.logger.info("[cdp][poll][offramp] #{ramp.partner_user_ref} discovered " \
                        "to=#{ramp.to_address&.first(12)}… amount=#{ramp.sell_amount_value} " \
                        "#{ramp.sell_amount_currency} deadline=#{ramp.cashout_deadline_at&.iso8601}")
    end

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
