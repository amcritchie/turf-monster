class CreateGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :goals do |t|
      t.string :game_slug, null: false
      t.string :team_slug, null: false
      t.string :player_slug
      t.integer :minute
      t.string :slug, null: false
      t.timestamps null: false

      t.index :game_slug
      t.index :player_slug
      t.index :slug, unique: true
      t.index :team_slug
    end
  end
end
