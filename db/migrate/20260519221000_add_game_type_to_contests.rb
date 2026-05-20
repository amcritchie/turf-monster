class AddGameTypeToContests < ActiveRecord::Migration[7.2]
  def change
    add_column :contests, :game_type, :string, default: "turf_totals", null: false
    add_index :contests, :game_type
  end
end
