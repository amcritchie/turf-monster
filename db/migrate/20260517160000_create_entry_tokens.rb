class CreateEntryTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :entry_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.references :entry, null: true, foreign_key: true
      t.string :status, null: false, default: "purchased"
      t.string :source, null: false
      t.string :source_ref
      t.integer :price_cents, null: false, default: 0
      t.datetime :spent_at
      t.datetime :refunded_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :entry_tokens, [:user_id, :status]
    add_index :entry_tokens, :source_ref
  end
end
