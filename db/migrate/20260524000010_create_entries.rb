class CreateEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :entries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :contest, null: false, foreign_key: true
      t.float :score, default: 0.0, null: false
      t.string :status, default: "cart", null: false
      t.integer :rank
      t.integer :payout_cents, default: 0
      t.integer :entry_number
      t.string :onchain_entry_id
      t.string :onchain_tx_signature
      t.string :slug
      t.timestamps null: false
      t.integer :eliminated_round

      t.index [:contest_id, :status]
      t.index :slug, unique: true
      t.index :status
      t.index [:user_id, :contest_id, :entry_number],
              unique: true,
              where: "entry_number IS NOT NULL",
              name: "index_entries_on_user_contest_entry_number"
      t.index [:user_id, :contest_id]
    end
  end
end
