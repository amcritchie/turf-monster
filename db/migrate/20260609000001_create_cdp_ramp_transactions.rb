class CreateCdpRampTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :cdp_ramp_transactions do |t|
      t.bigint  :user_id, null: false
      t.string  :direction, null: false                       # enum onramp / offramp
      # Per-session correlation key sent to Coinbase as partnerUserRef
      # ("tm-<user_id>-<id>", < 50 chars). Assigned after_create (needs id).
      t.string  :partner_user_ref
      t.string  :wallet_address, null: false                  # the Solana pubkey the session token was minted for
      t.string  :wallet_mode, null: false                     # enum web2 (managed) / web3 (Phantom)
      # Local lifecycle: initiated → token_minted → returned → cdp_created →
      # sending → sent → success | failed | expired | abandoned
      t.string  :status, null: false, default: "initiated"
      t.string  :cdp_status                                   # raw CDP status string, stored verbatim
      t.string  :coinbase_transaction_id                      # idempotency key for poll/webhook upserts
      t.string  :tx_hash
      t.string  :to_address                                   # offramp: Coinbase-managed address we must send USDC to
      t.decimal :sell_amount_value, precision: 30, scale: 12  # parsed via BigDecimal, never Float
      t.string  :sell_amount_currency
      t.string  :asset, null: false, default: "USDC"
      t.string  :network, null: false, default: "solana"
      t.string  :payment_method
      t.jsonb   :raw_payload, default: {}
      t.datetime :returned_at                                 # redirect-page hit — UX signal only, never confirmation
      t.datetime :cashout_deadline_at                         # offramp: created_at + 30 minutes
      t.string :sent_signature                                # offramp: our USDC send signature
      t.timestamps

      t.index :user_id
      t.index :partner_user_ref, unique: true
      t.index :coinbase_transaction_id, unique: true
      t.index [:status, :direction]
    end
  end
end
