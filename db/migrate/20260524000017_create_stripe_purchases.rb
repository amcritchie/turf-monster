class CreateStripePurchases < ActiveRecord::Migration[7.2]
  def change
    create_table :stripe_purchases do |t|
      t.references :user, null: false, foreign_key: true
      t.string :stripe_customer_id
      t.string :stripe_session_id, null: false
      t.string :stripe_charge_id
      t.integer :quantity, default: 1, null: false
      t.integer :price_cents, null: false
      t.string :status, default: "pending", null: false
      t.text :mint_tx_signatures
      t.datetime :minted_at
      t.datetime :refunded_at
      t.string :refund_reason
      t.string :slug, null: false
      t.timestamps null: false

      t.index :slug, unique: true
      t.index :stripe_session_id, unique: true
    end
  end
end
