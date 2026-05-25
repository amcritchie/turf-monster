class CreateThemeSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :theme_settings do |t|
      t.string :app_name, null: false
      t.string :primary
      t.string :accent1
      t.string :accent2
      t.string :warning
      t.string :danger
      t.string :dark
      t.string :light
      t.string :slug
      t.timestamps null: false

      t.index :app_name, unique: true
    end
  end
end
