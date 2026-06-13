class CreateSiteSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :site_settings do |t|
      t.string :slug, null: false
      t.string :default_og_title
      t.string :default_og_description

      t.timestamps
    end

    add_index :site_settings, :slug, unique: true
  end
end
