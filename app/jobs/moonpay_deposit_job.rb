class MoonpayDepositJob < ApplicationJob
  queue_as :default

  def perform(user_id:, amount_cents:, wallet_address:, moonpay_tx_id:)
    # OPSEC-022: idempotency via dedicated indexed column.
    return if TransactionLog.exists?(moonpay_tx_id: moonpay_tx_id)

    user = User.find_by(id: user_id)
    return unless user

    onchain_tx = nil

    if user.managed_wallet?
      # MoonPay delivered USDC to the wallet's ATA — deposit into vault
      vault = Solana::Vault.new
      vault.ensure_user_account(wallet_address)
      amount_lamports = Solana::Config.dollars_to_lamports(amount_cents / 100.0)
      onchain_tx = vault.deposit(user.solana_keypair, amount_lamports)
    end
    # Phantom wallets: USDC already in ATA, no vault deposit needed

    # Record transaction (balance is on-chain, no DB credit needed)
    TransactionLog.record!(
      user: user,
      type: "deposit",
      amount_cents: amount_cents,
      direction: "credit",
      description: "MoonPay deposit $#{'%.2f' % (amount_cents / 100.0)}",
      onchain_tx: onchain_tx,
      metadata: { method: "moonpay" },
      moonpay_tx_id: moonpay_tx_id  # OPSEC-022
    )
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[MoonpayDepositJob] duplicate moonpay_tx_id=#{moonpay_tx_id} — already recorded")
  end
end
