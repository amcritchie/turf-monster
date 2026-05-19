class CreateSeasonConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :season_configs do |t|
      t.integer :current_season_id, null: false, default: 0
      t.string :slug, null: false, index: { unique: true }
      t.timestamps
    end
  end
end
