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
      return true if webhook_key.blank? # Skip in dev if not configured

      signature = request.env["HTTP_MOONPAY_SIGNATURE_V2"] || request.env["HTTP_MOONPAY_SIGNATURE"]
      return false unless signature

      expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_key, payload)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def handle_transaction_completed(data)
      moonpay_tx_id = data["id"]
      return if TransactionLog.exists?(metadata: { "moonpay_tx_id" => moonpay_tx_id })

      wallet_address = data["walletAddress"]
      # MoonPay amounts are in the crypto currency — USDC has 6 decimals
      crypto_amount = data["cryptoTransactionId"].present? ? data["quoteCurrencyAmount"].to_f : 0
      amount_cents = (crypto_amount * 100).to_i

      # Find user by wallet address
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
