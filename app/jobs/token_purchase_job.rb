# Stripe webhook → on-chain entry token mint (turf-vault v0.9.0+).
#
# Idempotency is per source_ref, anchored on what's already on-chain:
#   - "stripe:#{session_id}:#{i}" is the source_ref for token i of this purchase
#   - On entry we query Vault#list_entry_tokens and skip iterations whose
#     source_ref already exists. So a partial-failure (e.g. 2 of 3 minted then
#     crash) recovers on retry: the first 2 are skipped, the 3rd retried.
#   - Signatures are persisted to StripePurchase after each successful mint so
#     a mid-loop crash leaves recoverable state.
#   - StripePurchase rows with status "minted" are the terminal "done" marker.
#     "pending" / "failed" rows are mid-recovery and unblock reprocessing.
class TokenPurchaseJob < ApplicationJob
  queue_as :default

  def perform(user_id:, quantity:, wallet_address:, stripe_session_id:)
    sid_short = stripe_session_id[0, 24]
    Rails.logger.info "[tokens] job.start user=#{user_id} qty=#{quantity} wallet=#{wallet_address[0,12]}... sid=#{sid_short}..."

    purchase = StripePurchase.for_session(stripe_session_id).first
    if purchase&.status == "minted"
      Rails.logger.info "[tokens] job.skip already_minted sid=#{sid_short}..."
      return
    end

    user = User.find_by(id: user_id)
    unless user
      Rails.logger.warn "[tokens] job.skip user_not_found user_id=#{user_id} sid=#{sid_short}..."
      return
    end

    pack_price_cents = StripePurchase.pack_price_cents(quantity)
    purchase ||= StripePurchase.create!(
      user: user,
      stripe_session_id: stripe_session_id,
      quantity: quantity,
      price_cents: pack_price_cents,
      status: "pending"
    )
    purchase.update!(status: "pending") if purchase.status == "failed"
    Rails.logger.info "[tokens] job.purchase id=#{purchase.id} status=#{purchase.status} price=#{pack_price_cents}"

    # Attribute every Solana RPC call in this job back to this StripePurchase.
    Current.outbound_source = purchase
    Current.user            = user

    vault = Solana::Vault.new
    minted_refs = vault.list_entry_tokens(wallet_address)
                       .map { |t| t[:source_ref] }
                       .compact
                       .select { |r| r.start_with?("stripe:#{stripe_session_id}:") }
                       .to_set
    Rails.logger.info "[tokens] job.on_chain_already minted=#{minted_refs.size} of #{quantity}"

    signatures = purchase.tx_signatures.dup # restore any previously persisted

    quantity.times do |i|
      source_ref = "stripe:#{stripe_session_id}:#{i}"
      if minted_refs.include?(source_ref)
        Rails.logger.info "[tokens] job.skip_mint #{i + 1}/#{quantity} already_on_chain"
        next
      end

      Rails.logger.info "[tokens] job.mint #{i + 1}/#{quantity} source_ref=stripe:#{sid_short}...:#{i} program_id=#{Solana::Config::PROGRAM_ID[0,12]}..."
      result = vault.mint_entry_token(
        wallet_address: wallet_address,
        source: :stripe,
        source_ref: source_ref
      )
      signatures << result[:signature]
      # Persist incrementally — a crash on the next iteration won't lose this signature.
      purchase.update!(mint_tx_signatures: signatures.to_json)
      Rails.logger.info "[tokens] job.mint_ok #{i + 1}/#{quantity} sig=#{result[:signature][0,16]}... pda=#{result[:pda]&.[](0,12)}... seq=#{result[:sequence]}"
    end

    purchase.mark_minted!(signatures)
    Rails.logger.info "[tokens] job.minted purchase_id=#{purchase.id} signatures=#{signatures.length}"

    TransactionLog.record!(
      user: user,
      type: "token_purchase",
      amount_cents: pack_price_cents,
      direction: "credit",
      description: "Bought #{quantity} entry token#{'s' if quantity != 1} ($#{'%.2f' % (pack_price_cents / 100.0)}) — minted on-chain",
      onchain_tx: signatures.first,
      metadata: { stripe_session_id: stripe_session_id, method: "stripe", quantity: quantity, all_signatures: signatures }
    )
    Rails.logger.info "[tokens] job.complete sid=#{sid_short}..."
  rescue => e
    Rails.logger.error "[tokens] job.error class=#{e.class} message=#{e.message} purchase_id=#{purchase&.id}"
    Rails.logger.error "[tokens] job.error_backtrace=#{e.backtrace.first(6).join(' | ')}" if e.backtrace
    purchase&.update(status: "failed")
    raise
  end
end
