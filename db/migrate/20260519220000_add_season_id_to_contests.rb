class AddSeasonIdToContests < ActiveRecord::Migration[7.2]
  def change
    # OPSEC-023: the season each contest is bound to (mirrors Contest.season_id
    # on the turf-vault PDA). Set at creation from SeasonConfig.current_season_id.
    add_column :contests, :season_id, :integer
  end
end
