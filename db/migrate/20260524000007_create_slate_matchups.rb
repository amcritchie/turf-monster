class CreateSlateMatchups < ActiveRecord::Migration[7.2]
  def change
    create_table :slate_matchups do |t|
      t.references :slate, null: false, foreign_key: true
      t.string :team_slug, null: false
      t.string :opponent_team_slug
      t.string :game_slug
      t.integer :rank
      t.decimal :turf_score, precision: 3, scale: 1
      t.integer :goals
      t.string :status, default: "pending", null: false
      t.decimal :dk_goals_expectation, precision: 3, scale: 1
      t.string :slug
      t.timestamps null: false

      t.index :game_slug
      t.index [:slate_id, :team_slug], unique: true
      t.index :slug, unique: true
      t.index :status
    end
  end
end
