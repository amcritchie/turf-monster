class CreateTeams < ActiveRecord::Migration[7.2]
  def change
    create_table :teams do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :short_name
      t.string :location
      t.string :emoji
      t.string :color_primary
      t.string :color_secondary
      t.timestamps null: false

      t.index :slug, unique: true
    end
  end
end
