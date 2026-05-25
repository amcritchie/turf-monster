class CreateContests < ActiveRecord::Migration[7.2]
  def change
    create_table :contests do |t|
      t.string :name, null: false
      t.string :contest_type, default: "small", null: false
      t.integer :entry_fee_cents, default: 0, null: false
      t.string :status, default: "pending", null: false
      t.integer :max_entries
      t.string :tagline
      t.integer :rank
      t.datetime :starts_at
      t.references :slate, foreign_key: true
      t.string :onchain_contest_id
      t.boolean :onchain_settled, default: false, null: false
      t.string :onchain_tx_signature
      t.string :slug
      t.timestamps null: false
      t.references :user, foreign_key: true
      t.string :locks_at_date_selected
      t.string :locks_at_time_selected
      t.string :locks_at_timezone_selected
      t.integer :season_id
      t.boolean :chat_enabled, default: true, null: false
      t.string :game_type, default: "turf_totals", null: false

      t.index :game_type
      t.index :rank
      t.index :slug, unique: true
      t.index :status
    end
  end
end
