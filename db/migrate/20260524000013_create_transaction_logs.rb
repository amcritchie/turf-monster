class CreateTransactionLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :transaction_logs do |t|
      t.string :transaction_type, null: false
      t.integer :amount_cents, null: false
      t.string :direction, null: false
      t.integer :balance_after_cents
      t.references :user, null: false, foreign_key: true
      t.string :source_type
      t.bigint :source_id
      t.string :source_name
      t.string :description
      t.string :status, default: "completed", null: false
      t.string :onchain_tx
      t.jsonb :metadata, default: {}
      t.string :slug
      t.timestamps null: false
      t.string :stripe_session_id
      t.string :moonpay_tx_id

      t.index :moonpay_tx_id,
              unique: true,
              where: "moonpay_tx_id IS NOT NULL",
              name: "index_transaction_logs_on_moonpay_tx_id_unique"
      t.index :slug, unique: true
      t.index [:source_type, :source_id]
      t.index :status
      t.index :stripe_session_id,
              unique: true,
              where: "stripe_session_id IS NOT NULL",
              name: "index_transaction_logs_on_stripe_session_id_unique"
      t.index :transaction_type
      t.index [:user_id, :status]
      t.index [:user_id, :transaction_type],
              name: "index_transaction_logs_on_user_id_and_type"
    end
  end
end
