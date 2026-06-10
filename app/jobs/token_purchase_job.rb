# Fiat purchase (Stripe webhook / PayPal capture) → on-chain entry token mint
# (turf-vault v0.9.0+). `purchase_type` picks the audit model: "stripe"
# (default — StripePurchase, keyed by stripe_session_id) or "paypal"
# (PaypalPurchase, keyed by paypal_order_id; the row always exists before the
# job is enqueued).
#
# Idempotency (OPSEC-009): per-mint incremental persistence so a partial
# failure (e.g. 2 of 3 minted then crash) recovers on retry without
# re-minting or losing the audit trail:
#   - "#{purchase_type}:#{purchase.id}:#{i}" is the source_ref for token i of
#     this purchase. NOT the provider's external id: Stripe session ids are
#     ~66 chars, and with the "stripe:" prefix + ":#{i}" suffix they overflowed
#     the on-chain [u8;64] source_ref field, which silently truncated the
#     ":#{i}" — so every token in a multi-token purchase hashed to ONE PDA and
#     collided on init (custom program error 0x0). The numeric purchase id
#     keeps the ref short, unique-per-token (the type prefix disambiguates the
#     two id sequences), and stable for retries; the readable external-id →
#     purchase mapping lives in the DB row.
#   - Each successful mint persists its signature to the purchase row
#     immediately. A crash on the next iteration leaves the prior signatures
#     in the DB as the resume point.
#   - On retry, we start the loop at `already_minted = tx_signatures.length`
#     and continue to `quantity`. The DB row is the source of truth for
#     resume — the on-chain PDA `init` constraint is a backstop that would
#     catch any over-mint via Anchor error.
#   - Only `status == "minted"` short-circuits the job. "pending" / "captured"
#     / "failed" rows are mid-recovery and must run through the loop to resume.
class TokenPurchaseJob < ApplicationJob
  queue_as :default

  def perform(user_id:, pack_id:, wallet_address:, stripe_session_id: nil, purchase_type: "stripe", paypal_order_id: nil)
    paypal           = purchase_type == "paypal"
    ref              = paypal ? paypal_order_id : stripe_session_id
    ref_short        = ref.to_s[0, 24]
    pack             = StripePurchase.pack(pack_id)
    quantity         = pack[:quantity]
    pack_price_cents = pack[:price_cents]
    Rails.logger.info "[tokens] job.start user=#{user_id} provider=#{purchase_type} pack=#{pack_id} qty=#{quantity} wallet=#{wallet_address[0,12]}... ref=#{ref_short}... program_id=#{Solana::Config::PROGRAM_ID[0,12]}..."

    # Catches stale Sidekiq env (mint-to-wrong-program bug, hit twice on devnet
    # redeploys). Raises StaleEnvError if PROGRAM_ID doesn't exist on the
    # configured RPC. Cached 5 minutes per (PROGRAM_ID, RPC_URL) tuple, so
    # the per-job cost amortizes to ~0 RPCs once the first job warms it.
    Solana::Vault.ensure_program_id_live! unless ENV["SKIP_PROGRAM_ID_LIVE_CHECK"] == "true"

    purchase = paypal ? PaypalPurchase.for_order(paypal_order_id).first
                      : StripePurchase.for_session(stripe_session_id).first
    if purchase&.status == "minted"
      Rails.logger.info "[tokens] job.skip already_minted ref=#{ref_short}..."
      return
    end

    user = User.find_by(id: user_id)
    unless user
      Rails.logger.warn "[tokens] job.skip user_not_found user_id=#{user_id} ref=#{ref_short}..."
      return
    end

    if paypal
      # PaypalPurchase rows are created BEFORE the PayPal order exists (see
      # TokensController#paypal_order) — a missing row means nothing to mint
      # against, never something to create here.
      unless purchase
        Rails.logger.warn "[tokens] job.skip paypal_purchase_not_found ref=#{ref_short}..."
        return
      end
      # "captured" is PayPal's mint-eligible state; restore it on retry after
      # a failed run (mirrors the stripe failed → pending recovery below).
      purchase.update!(status: "captured") if purchase.status == "failed"
    else
      purchase ||= StripePurchase.create!(
        user: user,
        stripe_session_id: stripe_session_id,
        quantity: quantity,
        price_cents: pack_price_cents,
        status: "pending"
      )
      purchase.update!(status: "pending") if purchase.status == "failed"
    end
    Rails.logger.info "[tokens] job.purchase provider=#{purchase_type} id=#{purchase.id} status=#{purchase.status} price=#{pack_price_cents}"

    # Attribute every Solana RPC call in this job back to this purchase row.
    Current.outbound_source = purchase
    Current.user            = user

    vault = Solana::Vault.new

    # Resume point: count signatures we've already persisted to the DB.
    # A previous run that crashed mid-loop has its successful mints persisted
    # here, so the retry picks up at exactly the next un-minted index.
    signatures    = purchase.tx_signatures.dup
    already_minted = signatures.length
    Rails.logger.info "[tokens] job.resume already_minted=#{already_minted} of #{quantity}"

    if already_minted >= quantity
      # Defensive: signatures already cover the full quantity. Treat as done.
      Rails.logger.info "[tokens] job.signatures_complete already_have=#{already_minted}, marking minted"
    else
      (already_minted...quantity).each do |i|
        source_ref = "#{purchase_type}:#{purchase.id}:#{i}"
        Rails.logger.info "[tokens] job.mint #{i + 1}/#{quantity} source_ref=#{source_ref} program_id=#{Solana::Config::PROGRAM_ID[0,12]}..."
        result = vault.mint_entry_token(
          wallet_address: wallet_address,
          source: purchase_type.to_sym,
          source_ref: source_ref
        )
        signatures << result[:signature]
        # Persist incrementally — a crash on the next iteration won't lose this signature.
        purchase.update!(mint_tx_signatures: signatures.to_json)
        Rails.logger.info "[tokens] job.mint_ok #{i + 1}/#{quantity} sig=#{result[:signature][0,16]}... pda=#{result[:pda]&.[](0,12)}..."
      end
    end

    purchase.mark_minted!(signatures)
    user.bust_entry_tokens_cache!
    Rails.logger.info "[tokens] job.minted purchase_id=#{purchase.id} signatures=#{signatures.length}"

    metadata = paypal ?
      { paypal_order_id: paypal_order_id, method: "paypal", quantity: quantity, all_signatures: signatures } :
      { stripe_session_id: stripe_session_id, method: "stripe", quantity: quantity, all_signatures: signatures }
    TransactionLog.record!(
      user: user,
      type: "token_purchase",
      amount_cents: pack_price_cents,
      direction: "credit",
      description: "Bought #{quantity} entry token#{'s' if quantity != 1} ($#{'%.2f' % (pack_price_cents / 100.0)}) — minted on-chain",
      onchain_tx: signatures.first,
      metadata: metadata
    )
    Rails.logger.info "[tokens] job.complete ref=#{ref_short}..."
  rescue => e
    Rails.logger.error "[tokens] job.error class=#{e.class} message=#{e.message} purchase_id=#{purchase&.id}"
    Rails.logger.error "[tokens] job.error_backtrace=#{e.backtrace.first(6).join(' | ')}" if e.backtrace
    # H8 prelaunch audit: never downgrade a minted purchase to failed — the
    # on-chain mint succeeded even if a post-mint step (e.g. TransactionLog
    # write) raised.
    purchase&.mark_failed_unless_minted!
    raise
  end
end
