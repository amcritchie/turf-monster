class CreateGeoSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :geo_settings do |t|
      t.string :app_name, null: false
      t.boolean :enabled, default: false, null: false
      t.jsonb :banned_states, default: []
      t.string :slug
      t.timestamps null: false

      t.index :app_name, unique: true
      t.index :slug, unique: true
    end
  end
end
