class CreatePendingTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :pending_transactions do |t|
      t.string :tx_type, null: false
      t.text :serialized_tx, null: false
      t.string :status, default: "pending", null: false
      t.string :target_type
      t.bigint :target_id
      t.string :initiator_address
      t.string :cosigner_address
      t.string :tx_signature
      t.jsonb :metadata, default: {}
      t.string :slug
      t.timestamps null: false

      t.index :slug, unique: true
      t.index :status
      t.index [:target_type, :target_id], name: "index_pending_transactions_on_target"
    end
  end
end
