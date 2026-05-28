# Stripe webhook → on-chain entry token mint (turf-vault v0.9.0+).
#
# Idempotency (OPSEC-009): per-mint incremental persistence so a partial
# failure (e.g. 2 of 3 minted then crash) recovers on retry without
# re-minting or losing the audit trail:
#   - "stripe:#{session_id}:#{i}" is the source_ref for token i of this purchase
#   - Each successful mint persists its signature to StripePurchase
#     immediately. A crash on the next iteration leaves the prior signatures
#     in the DB as the resume point.
#   - On retry, we start the loop at `already_minted = tx_signatures.length`
#     and continue to `quantity`. The DB row is the source of truth for
#     resume — the on-chain PDA `init` constraint is a backstop that would
#     catch any over-mint via Anchor error.
#   - Only `status == "minted"` short-circuits the job. "pending" / "failed"
#     rows are mid-recovery and must run through the loop to resume.
class TokenPurchaseJob < ApplicationJob
  queue_as :default

  def perform(user_id:, pack_id:, wallet_address:, stripe_session_id:)
    sid_short        = stripe_session_id[0, 24]
    pack             = StripePurchase.pack(pack_id)
    quantity         = pack[:quantity]
    pack_price_cents = pack[:price_cents]
    Rails.logger.info "[tokens] job.start user=#{user_id} pack=#{pack_id} qty=#{quantity} wallet=#{wallet_address[0,12]}... sid=#{sid_short}... program_id=#{Solana::Config::PROGRAM_ID[0,12]}..."

    # Catches stale Sidekiq env (mint-to-wrong-program bug, hit twice on devnet
    # redeploys). Raises StaleEnvError if PROGRAM_ID doesn't exist on the
    # configured RPC. Cached 5 minutes per (PROGRAM_ID, RPC_URL) tuple, so
    # the per-job cost amortizes to ~0 RPCs once the first job warms it.
    Solana::Vault.ensure_program_id_live! unless ENV["SKIP_PROGRAM_ID_LIVE_CHECK"] == "true"

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
        source_ref = "stripe:#{stripe_session_id}:#{i}"
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
    end

    purchase.mark_minted!(signatures)
    user.bust_entry_tokens_cache!
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
    # H8 prelaunch audit: never downgrade a minted purchase to failed — the
    # on-chain mint succeeded even if a post-mint step (e.g. TransactionLog
    # write) raised.
    purchase&.mark_failed_unless_minted!
    raise
  end
end
