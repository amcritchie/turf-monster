class StripeDepositJob < ApplicationJob
  queue_as :default

  # v0.16: deposit-to-vault is gone. USDC now lands in the user's own ATA
  # (managed or Phantom — same destination, same flow). No `vault.deposit`
  # step afterwards; the user's USDC is immediately spendable from their
  # ATA via enter_contest's SPL transfer.
  def perform(user_id:, amount_cents:, wallet_address:, stripe_session_id:)
    # OPSEC-022: idempotency via dedicated indexed column instead of JSONB
    # scan. Race-safe (DB unique partial index catches concurrent inserts).
    return if TransactionLog.exists?(stripe_session_id: stripe_session_id)

    user = User.find_by(id: user_id)
    return unless user

    vault = Solana::Vault.new
    amount_lamports = Solana::Config.dollars_to_lamports(amount_cents / 100.0)

    # Ensure user has both a UserAccount PDA (stats + seeds + username) and
    # a USDC ATA (where the funds will land).
    vault.ensure_user_account(wallet_address, username: user.username) if user.solana_connected?
    vault.ensure_ata(wallet_address, mint: Solana::Config::USDC_MINT)

    # Devnet: mint USDC to user ATA. Mainnet: transfer USDC from admin
    # treasury ATA to user ATA. Either way, that's the entire on-chain
    # operation for a deposit in v0.16.
    fund_result = vault.fund_user(wallet_address, amount_lamports)
    onchain_tx  = fund_result[:signature]

    TransactionLog.record!(
      user: user,
      type: "deposit",
      amount_cents: amount_cents,
      direction: "credit",
      description: "Stripe deposit $#{'%.2f' % (amount_cents / 100.0)}",
      onchain_tx: onchain_tx,
      metadata: { method: "stripe" },
      stripe_session_id: stripe_session_id  # OPSEC-022
    )
  rescue ActiveRecord::RecordNotUnique
    # Concurrent webhook delivery beat us to the insert — that's fine,
    # the other worker recorded it. No double-deposit.
    Rails.logger.info("[StripeDepositJob] duplicate stripe_session_id=#{stripe_session_id} — already recorded")
  end
end
