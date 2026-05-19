module Webhooks
  class MoonpayController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    def create
      payload = request.body.read

      unless verify_signature(payload)
        return head :bad_request
      end

      event = JSON.parse(payload)
      event_type = event["type"]

      case event_type
      when "transaction_completed"
        handle_transaction_completed(event["data"])
      end

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def verify_signature(payload)
      webhook_key = Rails.application.config.moonpay[:webhook_key]

      # OPSEC-006: fail-closed in production. A blank key in prod means
      # someone forgot to set MOONPAY_WEBHOOK_KEY on Heroku and we'd
      # otherwise accept unsigned POSTs from anywhere on the internet.
      if webhook_key.blank?
        return false if Rails.env.production?
        Rails.logger.warn("[moonpay] webhook_key blank — skipping signature verification (non-production)")
        return true
      end

      signature = request.env["HTTP_MOONPAY_SIGNATURE_V2"] || request.env["HTTP_MOONPAY_SIGNATURE"]
      return false unless signature

      expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_key, payload)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def handle_transaction_completed(data)
      moonpay_tx_id = data["id"]
      # OPSEC-022: idempotency via indexed column.
      return if TransactionLog.exists?(moonpay_tx_id: moonpay_tx_id)

      wallet_address = data["walletAddress"]

      # OPSEC-035 (FIXME before mainnet enable): MoonPay's BUY payload uses
      # baseCurrency = the asset being purchased (USDC), quoteCurrency = the
      # fiat the user paid (USD). For our purposes the crypto amount lives
      # in baseCurrencyAmount. Trust the webhook payload here is provisional
      # — for production we should re-fetch via the MoonPay API
      # (GET /v3/transactions/:id) and use that response as authoritative.
      crypto_amount =
        if data["cryptoTransactionId"].present?
          (data["baseCurrencyAmount"] || data["quoteCurrencyAmount"]).to_f
        else
          0
        end
      amount_cents = (crypto_amount * 100).to_i

      # OPSEC-061: user attribution by wallet address is spoofable in theory.
      # For now we accept it because (a) Solana addresses are user-supplied
      # so spoofing only affects the spoofer, and (b) on-chain USDC is the
      # source of truth — a forged "credit" here just creates a misleading
      # audit row, it does not move money. When we add server-side order
      # registration we should look up via externalCustomerId instead.
      user = User.find_by(web2_solana_address: wallet_address) ||
             User.find_by(web3_solana_address: wallet_address)
      return unless user

      MoonpayDepositJob.perform_later(
        user_id: user.id,
        amount_cents: amount_cents,
        wallet_address: wallet_address,
        moonpay_tx_id: moonpay_tx_id
      )
    end
  end
end
