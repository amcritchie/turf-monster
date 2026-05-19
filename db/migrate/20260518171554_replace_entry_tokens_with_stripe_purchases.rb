class ReplaceEntryTokensWithStripePurchases < ActiveRecord::Migration[7.2]
  def up
    # Entry tokens are now on-chain EntryTokenAccount PDAs in turf-vault (v0.9.0+).
    # The DB no longer tracks token balances — only Stripe purchase audit / refund metadata.
    drop_table :entry_tokens, if_exists: true

    create_table :stripe_purchases do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :stripe_customer_id
      t.string  :stripe_session_id, null: false, index: { unique: true }
      t.string  :stripe_charge_id
      t.integer :quantity,    null: false, default: 1   # number of tokens minted
      t.integer :price_cents, null: false               # total paid
      t.string  :status,      null: false, default: "pending" # pending / minted / refunded / failed
      t.text    :mint_tx_signatures                     # JSON-encoded array of on-chain mint TX sigs
      t.datetime :minted_at
      t.datetime :refunded_at
      t.string  :refund_reason
      t.string  :slug, null: false, index: { unique: true }
      t.timestamps
    end
  end

  def down
    drop_table :stripe_purchases
    create_table :entry_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.references :entry, foreign_key: true
      t.string :status, null: false, default: "purchased"
      t.string :source, null: false
      t.string :source_ref
      t.integer :price_cents, null: false
      t.datetime :spent_at
      t.datetime :refunded_at
      t.datetime :expires_at
      t.string :slug, null: false, index: { unique: true }
      t.timestamps
    end
  end
end
