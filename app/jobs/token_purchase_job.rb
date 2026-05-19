# Stripe webhook → on-chain entry token mint (turf-vault v0.9.0+).
# Idempotent via stripe_session_id (unique index on stripe_purchases.stripe_session_id +
# the Anchor mint_entry_token PDA collision rejecting duplicate sequences).
class TokenPurchaseJob < ApplicationJob
  queue_as :default

  def perform(user_id:, quantity:, wallet_address:, stripe_session_id:)
    return if StripePurchase.for_session(stripe_session_id).exists?

    user = User.find_by(id: user_id)
    return unless user

    pack_price_cents = StripePurchase.pack_price_cents(quantity)
    purchase = StripePurchase.create!(
      user: user,
      stripe_session_id: stripe_session_id,
      quantity: quantity,
      price_cents: pack_price_cents,
      status: "pending"
    )

    vault = Solana::Vault.new
    signatures = []
    quantity.times do |i|
      result = vault.mint_entry_token(
        wallet_address: wallet_address,
        source: :stripe,
        source_ref: "stripe:#{stripe_session_id}:#{i}"
      )
      signatures << result[:signature]
    end
    purchase.mark_minted!(signatures)

    TransactionLog.record!(
      user: user,
      type: "token_purchase",
      amount_cents: pack_price_cents,
      direction: "credit",
      description: "Bought #{quantity} entry token#{'s' if quantity != 1} ($#{'%.2f' % (pack_price_cents / 100.0)}) — minted on-chain",
      onchain_tx: signatures.first,
      metadata: { stripe_session_id: stripe_session_id, method: "stripe", quantity: quantity, all_signatures: signatures }
    )
  rescue => e
    purchase&.update(status: "failed")
    raise
  end
end
