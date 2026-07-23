module Webhooks
  # Coinflow webhook handler — the Coinflow-rails sibling of
  # Webhooks::PaypalController.
  #
  # Fulfillment source of truth: the `Settled` event (funds reached settlement)
  # → validate-then-mint. `Card Payment Authorized` is pre-capture (log only).
  # Coinflow authenticates with a SHARED SECRET (Authorization header ==
  # COINFLOW_WEBHOOK_VALIDATION_KEY), NOT an HMAC signature. Exactly-once minting
  # is arbitrated by CoinflowPurchase#begin_fulfillment! via Coinflow::Fulfillment.
  class CoinflowController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    def create
      raw_body = request.body.read

      # Shared-secret auth FIRST — cheap, constant-time, fails closed. A wrong
      # (or missing) Authorization header is the whole defense between an
      # attacker and free token minting.
      unless Coinflow::Client.new.verify_webhook_auth(request.headers["Authorization"])
        Rails.logger.warn "[tokens] coinflow.webhook.bad_auth"
        return head :unauthorized
      end

      begin
        event = JSON.parse(raw_body)
      rescue JSON::ParserError
        Rails.logger.warn "[tokens] coinflow.webhook.bad_json"
        return head :bad_request
      end

      event_type = (event["eventType"] || event["type"]).to_s
      payment_id = event["id"].to_s
      Rails.logger.info "[tokens] coinflow.webhook.received type=#{event_type} id=#{payment_id}"

      # OPSEC-033 parity: refuse sandbox events in production at the controller
      # boundary. A sandbox-configured client (COINFLOW_API_BASE) is the tell.
      # Return 200 to ack (never retry-loop the sender).
      if Rails.env.production? && Coinflow::Client.sandbox?
        Rails.logger.warn "[tokens] coinflow.webhook.rejected_sandbox_event_in_production type=#{event_type} id=#{payment_id}"
        return head :ok
      end

      # OPSEC-033 parity: an event for a different merchant is not ours.
      merchant_id = ENV["COINFLOW_MERCHANT_ID"].to_s
      if merchant_id.present? && event["merchantId"].present? && event["merchantId"].to_s != merchant_id
        Rails.logger.warn "[tokens] coinflow.webhook.merchant_mismatch event_merchant=#{event['merchantId']} id=#{payment_id}"
        return head :ok
      end

      case event_type
      when "Settled"
        handle_settled(event)
      when "Card Payment Authorized"
        # Pre-capture authorization — funds NOT yet settled. Log only; the
        # `Settled` event is what mints.
        Rails.logger.info "[tokens] coinflow.webhook.card_authorized id=#{payment_id} (pre-settlement, no mint)"
      else
        Rails.logger.info "[tokens] coinflow.webhook.ignored type=#{event_type} id=#{payment_id}"
      end

      head :ok
    end

    private

    # `Settled` — funds reached settlement. Resolve the purchase, dedup a
    # redelivered event, validate the amount against the pack (never trust the
    # sender), then hand off to the exactly-once mint gate.
    def handle_settled(event)
      payment_id = event["id"].to_s
      purchase   = purchase_for_event(event)
      unless purchase
        Rails.logger.error "[tokens] coinflow.webhook.settled UNMATCHED id=#{payment_id} " \
                           "customer=#{event['customerId']} — manual review required"
        return
      end

      TokensLogger.dump("coinflow.webhook.settled_payload", {
        payment_id: payment_id,
        subtotal: event["subtotal"],
        fees: event["fees"],
        total: event["total"],
        merchant_id: event["merchantId"],
        customer_id: event["customerId"]
      })

      # Dedup (webhooks may arrive more than once): this exact settlement already
      # drove this purchase to minted — ack and stop.
      if purchase.coinflow_payment_id == payment_id && purchase.status == "minted"
        Rails.logger.info "[tokens] coinflow.webhook.duplicate id=#{payment_id} purchase=#{purchase.id} already minted"
        return
      end

      unless purchase.capture_matches?(event)
        Rails.logger.warn "[tokens] coinflow.webhook.settled_rejected purchase=#{purchase.id} " \
                          "subtotal=#{subtotal_field(event, 'cents')} " \
                          "currency=#{subtotal_field(event, 'currency')} " \
                          "expected=#{purchase.expected_amount_cents}"
        return
      end

      if Coinflow::Fulfillment.enqueue_mint!(purchase, payment_id: payment_id)
        Rails.logger.info "[tokens] coinflow.webhook.job_enqueued purchase=#{purchase.id}"
      else
        Rails.logger.info "[tokens] coinflow.webhook.already_fulfilled purchase=#{purchase.id} status=#{purchase.status}"
      end
    end

    # Tiered resolution (Webhooks::PaypalController#purchase_for_capture
    # parity). Coinflow's create-checkout-link body carries no invoice field, so
    # the primary path is the customerId echoed from x-coinflow-auth-user-id.
    #   Tier 1 — an explicit reference field, if the payload carries one.
    #   Tier 2 — customerId AS a reference (if the operator keys
    #            x-coinflow-auth-user-id to the reference).
    #   Tier 3 — customerId as "tm_user_<id>" → the user's oldest pending row
    #            (oldest-first so N concurrent settlements consume N pending
    #            rows, one token each — never double-minting one row).
    def purchase_for_event(event)
      reference = event["reference"].presence || subtotal_field(event, "reference").presence
      if reference && (purchase = CoinflowPurchase.for_reference(reference).first)
        return purchase
      end

      customer_id = event["customerId"].to_s
      if customer_id.present? && (purchase = CoinflowPurchase.for_reference(customer_id).first)
        return purchase
      end

      if (user_id = customer_id[/\Atm_user_(\d+)\z/, 1])
        return CoinflowPurchase.where(user_id: user_id, status: "pending").order(:created_at).first
      end

      nil
    end

    # Fail-closed read of a `subtotal` sub-field. Coinflow documents `subtotal`
    # as a {cents:, currency:} hash; a malformed payload (e.g. a bare integer)
    # would make `event.dig("subtotal", key)` raise TypeError → a webhook 500
    # (and a Coinflow retry-loop). Read every subtotal sub-field through this so
    # a malformed payload degrades to nil, mirroring
    # CoinflowPurchase#capture_matches? — no mint, ack the sender, never 500.
    def subtotal_field(event, key)
      subtotal = event["subtotal"]
      subtotal.is_a?(Hash) ? subtotal[key] : nil
    end
  end
end
