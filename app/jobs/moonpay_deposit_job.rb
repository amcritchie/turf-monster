class MoonpayDepositJob < ApplicationJob
  queue_as :default

  # v0.16: MoonPay delivers USDC directly to the user's ATA — no follow-up
  # vault deposit. The job's only post-MoonPay responsibility is to make sure
  # the supporting on-chain accounts exist (UserAccount PDA for stats) and
  # to write the audit log.
  def perform(user_id:, amount_cents:, wallet_address:, moonpay_tx_id:)
    # OPSEC-022: idempotency via dedicated indexed column.
    return if TransactionLog.exists?(moonpay_tx_id: moonpay_tx_id)

    user = User.find_by(id: user_id)
    return unless user

    if user.solana_connected?
      vault = Solana::Vault.new
      vault.ensure_user_account(wallet_address, username: user.username)
      vault.ensure_ata(wallet_address, mint: Solana::Config::USDC_MINT)
    end

    # v0.16: USDC is already in the user's ATA — MoonPay sent it there.
    # No further on-chain action needed. onchain_tx is nil because the
    # MoonPay transfer wasn't a Rails-initiated TX.
    TransactionLog.record!(
      user: user,
      type: "deposit",
      amount_cents: amount_cents,
      direction: "credit",
      description: "MoonPay deposit $#{'%.2f' % (amount_cents / 100.0)}",
      onchain_tx: nil,
      metadata: { method: "moonpay" },
      moonpay_tx_id: moonpay_tx_id  # OPSEC-022
    )
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[MoonpayDepositJob] duplicate moonpay_tx_id=#{moonpay_tx_id} — already recorded")
  end
end
