class CreatePlayers < ActiveRecord::Migration[7.2]
  def change
    create_table :players do |t|
      t.string :slug, null: false
      t.string :team_slug
      t.string :name, null: false
      t.string :position
      t.integer :jersey_number
      t.timestamps null: false

      t.index :slug, unique: true
      t.index :team_slug
    end
  end
end
