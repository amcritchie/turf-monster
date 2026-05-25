class CreateGames < ActiveRecord::Migration[7.2]
  def change
    create_table :games do |t|
      t.string :slug, null: false
      t.string :home_team_slug, null: false
      t.string :away_team_slug, null: false
      t.datetime :kickoff_at
      t.string :venue
      t.string :status, default: "scheduled"
      t.integer :home_score
      t.integer :away_score
      t.timestamps null: false
      t.references :survivor_round, foreign_key: true
      t.string :advancing_team_slug

      t.index :slug, unique: true
      t.index :home_team_slug
      t.index :away_team_slug
      t.index :status
    end
  end
end
