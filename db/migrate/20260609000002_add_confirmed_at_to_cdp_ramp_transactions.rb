class AddConfirmedAtToCdpRampTransactions < ActiveRecord::Migration[7.2]
  def change
    # §10 send guard: the FRESH explicit user confirmation that gates the
    # server-signed offramp USDC send (Cdp::OfframpSendJob). Stamped by
    # POST /cdp/offramp/confirm_send (managed) / prepare_send (Phantom);
    # the send job refuses when blank or stale.
    add_column :cdp_ramp_transactions, :confirmed_at, :datetime
  end
end
