class AddSurvivorFieldsToGames < ActiveRecord::Migration[7.2]
  def change
    # Links a match to a survivor round (group matchdays + knockout rounds).
    # Nullable — Turf Totals games leave it blank.
    add_reference :games, :survivor_round, foreign_key: true, null: true
    # Knockout winner after extra time / penalties, where the score can be level.
    add_column :games, :advancing_team_slug, :string
  end
end
