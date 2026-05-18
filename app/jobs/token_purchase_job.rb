class TokenPurchaseJob < ApplicationJob
  queue_as :default

  def perform(user_id:, quantity:, wallet_address:, stripe_session_id:)
    return if EntryToken.for_source_ref(stripe_session_id).exists?

    user = User.find_by(id: user_id)
    return unless user

    pack_price_cents = EntryToken.pack_price_cents(quantity)
    usdc_mint = Solana::Config::USDC_MINT
    topup_lamports = Solana::Config.dollars_to_lamports(quantity * 19.0)

    vault = Solana::Vault.new
    vault.ensure_ata(wallet_address, mint: usdc_mint)
    fund_result = vault.fund_user(wallet_address, topup_lamports)

    EntryToken.purchase!(user: user, quantity: quantity, source: "stripe", source_ref: stripe_session_id)

    TransactionLog.record!(
      user: user,
      type: "token_purchase",
      amount_cents: pack_price_cents,
      direction: "credit",
      description: "Bought #{quantity} entry token#{'s' if quantity != 1} ($#{'%.2f' % (pack_price_cents / 100.0)})",
      onchain_tx: fund_result&.dig(:signature),
      metadata: { stripe_session_id: stripe_session_id, method: "stripe", quantity: quantity }
    )

    Rails.cache.delete("usdc_balance:#{user.id}")
  end
end
