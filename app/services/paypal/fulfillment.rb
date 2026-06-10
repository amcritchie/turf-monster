module Paypal
  # Exactly-once bridge from a validated PayPal capture to the on-chain mint.
  # Shared by TokensController#paypal_capture and Webhooks::PaypalController —
  # both can learn about the same capture, and both funnel through here.
  module Fulfillment
    # How old a captured-but-unminted row must be before a redelivered webhook
    # treats it as stranded and re-enqueues. A fresh capture is almost always
    # mid-mint (a trio is several sequential Solana send_and_confirm round
    # trips) and PAYMENT.CAPTURE.COMPLETED routinely lands inside that window —
    # an immediate re-enqueue would run two jobs CONCURRENTLY racing the same
    # source_refs: the loser trips the on-chain PDA init backstop (custom
    # error 0x0) and its rescue transiently flips a genuinely-paid row to
    # "failed". Sized past the worst-case mint loop (3 × 30s confirm timeout)
    # plus the first Sidekiq retry.
    STRANDED_AFTER = 5.minutes

    module_function

    # Enqueues TokenPurchaseJob when this caller wins the atomic
    # pending → captured transition, OR when the row has been stranded
    # captured-but-unminted for longer than STRANDED_AFTER (a prior winner
    # crashed between the CAS and the mint completing). Fresh webhook
    # redeliveries while the winner's job is still minting are no-ops; the
    # job's idempotency (OPSEC-009 source_ref + minted short-circuit) remains
    # the backstop. Returns true when a job was enqueued.
    def enqueue_mint!(purchase, capture_id:)
      won = purchase.begin_fulfillment!(capture_id: capture_id)
      return false unless won || stranded?(purchase)

      # B4 / OPSEC-036/048: never mint for a frozen or risk-flagged account.
      # The capture above is still recorded (the money DID move — forensics
      # keep the trail), but the on-chain mint waits for operator review:
      # unfreeze/unflag, then re-enqueue via console or a PayPal dashboard
      # webhook resend (the stranded-row branch above picks it up).
      user = purchase.user
      if user.frozen? || user.payment_risk_flag
        Rails.logger.error "[tokens] paypal.mint_blocked purchase=#{purchase.id} user=#{user.id} " \
                           "frozen=#{user.frozen?} risk_flag=#{user.payment_risk_flag} " \
                           "— captured but NOT minting, manual review required"
        return false
      end

      TokenPurchaseJob.perform_later(
        user_id: purchase.user_id,
        pack_id: purchase.pack_id,
        wallet_address: purchase.wallet_address,
        purchase_type: "paypal",
        paypal_order_id: purchase.paypal_order_id
      )
      Rails.logger.info "[tokens] paypal.mint_enqueued purchase=#{purchase.id} order=#{purchase.paypal_order_id} won_cas=#{won}"
      true
    end

    # Captured, unminted, and old enough that the original job has clearly
    # died. A nil captured_at can't happen via the CAS — treat it as stale so
    # an anomalous row stays recoverable.
    def stranded?(purchase)
      purchase.status == "captured" &&
        purchase.tx_signatures.length < purchase.quantity &&
        (purchase.captured_at.nil? || purchase.captured_at <= STRANDED_AFTER.ago)
    end
  end
end
