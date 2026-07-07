class CreateNflTeamTotalProjections < ActiveRecord::Migration[7.2]
  def change
    create_table :nfl_team_total_projections do |t|
      t.integer :year, null: false
      t.integer :week, null: false
      t.references :slate, foreign_key: true
      t.string :game_slug, null: false
      t.string :team_slug, null: false
      t.string :opponent_team_slug, null: false
      t.boolean :home, null: false
      t.decimal :expected_points, precision: 5, scale: 2, null: false
      t.decimal :game_total, precision: 5, scale: 2, null: false
      t.decimal :home_spread, precision: 5, scale: 2, null: false
      t.string :favorite_team_slug, null: false
      t.decimal :favorite_spread, precision: 5, scale: 2, null: false
      t.string :source, null: false
      t.date :source_published_on
      t.string :source_url
      t.text :source_text
      t.datetime :cached_at, null: false

      t.timestamps
    end

    add_index :nfl_team_total_projections,
              [:year, :week, :game_slug, :team_slug],
              unique: true,
              name: "index_nfl_team_totals_unique_team_game"
    add_index :nfl_team_total_projections,
              [:year, :week, :expected_points],
              name: "index_nfl_team_totals_on_year_week_points"
    add_index :nfl_team_total_projections,
              [:year, :week, :team_slug],
              name: "index_nfl_team_totals_on_year_week_team"
    add_index :nfl_team_total_projections, :source
  end
end
