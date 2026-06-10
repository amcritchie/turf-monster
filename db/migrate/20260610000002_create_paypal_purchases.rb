class CreatePaypalPurchases < ActiveRecord::Migration[7.2]
  def change
    create_table :paypal_purchases do |t|
      t.references :user, null: false, foreign_key: true
      # Null until the PayPal order is created — the row exists first so
      # Current.outbound_source can attribute the create-order API call.
      t.string :paypal_order_id
      t.string :capture_id
      t.string :pack_id, null: false
      t.integer :quantity, default: 1, null: false
      t.integer :price_cents, null: false
      t.string :wallet_address
      t.string :contest_slug
      t.string :status, default: "pending", null: false
      t.text :mint_tx_signatures
      t.datetime :captured_at
      t.datetime :minted_at
      t.datetime :refunded_at
      t.string :refund_reason
      t.string :slug, null: false
      t.timestamps null: false

      t.index :slug, unique: true
      t.index :paypal_order_id, unique: true
      t.index :capture_id
    end
  end
end
