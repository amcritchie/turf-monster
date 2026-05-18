module Webhooks
  class StripeController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    def create
      payload = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
      webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]

      begin
        event = Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
      rescue JSON::ParserError
        return head :bad_request
      rescue Stripe::SignatureVerificationError
        return head :bad_request
      end

      case event.type
      when "checkout.session.completed"
        handle_checkout_completed(event.data.object)
      end

      head :ok
    end

    private

    def handle_checkout_completed(session)
      # Idempotency: skip if already processed
      stripe_session_id = session.id
      return if TransactionLog.exists?(metadata: { "stripe_session_id" => stripe_session_id })

      user_id        = session.metadata["user_id"]
      wallet_address = session.metadata["wallet_address"]

      if session.metadata["kind"] == "tokens"
        TokenPurchaseJob.perform_later(
          user_id: user_id,
          quantity: session.metadata["quantity"].to_i,
          wallet_address: wallet_address,
          stripe_session_id: stripe_session_id
        )
      else
        StripeDepositJob.perform_later(
          user_id: user_id,
          amount_cents: session.metadata["amount_cents"].to_i,
          wallet_address: wallet_address,
          stripe_session_id: stripe_session_id
        )
      end
    end
  end
end
