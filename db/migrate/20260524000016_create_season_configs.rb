class CreateSeasonConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :season_configs do |t|
      t.integer :current_season_id, default: 0, null: false
      t.string :slug, null: false
      t.timestamps null: false
      t.bigint :main_contest_id

      t.index :main_contest_id
      t.index :slug, unique: true
    end

    add_foreign_key :season_configs, :contests, column: :main_contest_id, on_delete: :nullify
  end
end
