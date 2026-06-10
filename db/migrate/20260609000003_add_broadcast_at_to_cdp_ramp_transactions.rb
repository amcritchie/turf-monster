class AddBroadcastAtToCdpRampTransactions < ActiveRecord::Migration[7.2]
  def change
    # Stamped by mark_sending! in the same write that persists sent_signature —
    # i.e. the actual broadcast-attempt time. Cdp::OfframpSendJob anchors its
    # blockhash-lapse verdict here, NOT on confirmed_at: the user's
    # confirmation can legally precede the broadcast by up to CONFIRMATION_TTL
    # (Sidekiq latency / retry backoff), and anchoring on confirmed_at could
    # declare a just-broadcast tx verified-dead while it is still landable —
    # reset + rebuild would then double-send USDC.
    add_column :cdp_ramp_transactions, :broadcast_at, :datetime
  end
end
