class CreateSurvivorPicks < ActiveRecord::Migration[7.2]
  def change
    create_table :survivor_picks do |t|
      t.references :entry, null: false, foreign_key: true
      t.references :survivor_round, null: false, foreign_key: true
      t.string :team_slug, null: false
      t.string :result, null: false, default: "pending"
      t.string :slug

      t.timestamps
    end

    # One pick per entry per round.
    add_index :survivor_picks, [:entry_id, :survivor_round_id], unique: true,
              name: "index_survivor_picks_on_entry_and_round"
    # No team reuse — each team usable at most once per entry.
    add_index :survivor_picks, [:entry_id, :team_slug], unique: true,
              name: "index_survivor_picks_on_entry_and_team"
    add_index :survivor_picks, :team_slug
    add_index :survivor_picks, :slug, unique: true
  end
end
