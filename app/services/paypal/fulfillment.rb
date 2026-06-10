module Paypal
  # Exactly-once bridge from a validated PayPal capture to the on-chain mint.
  # Shared by TokensController#paypal_capture and Webhooks::PaypalController —
  # both can learn about the same capture, and both funnel through here.
  module Fulfillment
    module_function

    # Enqueues TokenPurchaseJob when this caller wins the atomic
    # pending → captured transition, OR when the row is stranded
    # captured-but-unminted (a prior winner crashed between the CAS and the
    # enqueue, or PayPal redelivered the webhook). The job itself is
    # idempotent (OPSEC-009 source_ref + minted short-circuit), so the rare
    # double-enqueue is safe. Returns true when a job was enqueued.
    def enqueue_mint!(purchase, capture_id:)
      won = purchase.begin_fulfillment!(capture_id: capture_id)
      return false unless won || (purchase.status == "captured" && purchase.tx_signatures.length < purchase.quantity)

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
  end
end
