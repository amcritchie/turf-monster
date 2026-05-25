class CreateSurvivorPicks < ActiveRecord::Migration[7.2]
  def change
    create_table :survivor_picks do |t|
      t.references :entry, null: false, foreign_key: true
      t.references :survivor_round, null: false, foreign_key: true
      t.string :team_slug, null: false
      t.string :result, default: "pending", null: false
      t.string :slug
      t.timestamps null: false

      t.index [:entry_id, :survivor_round_id],
              unique: true,
              name: "index_survivor_picks_on_entry_and_round"
      t.index [:entry_id, :team_slug],
              unique: true,
              name: "index_survivor_picks_on_entry_and_team"
      t.index :slug, unique: true
      t.index :team_slug
    end
  end
end
