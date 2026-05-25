class CreateLandingPages < ActiveRecord::Migration[7.2]
  def change
    create_table :landing_pages do |t|
      t.string :name, null: false
      t.string :slug
      t.string :headline
      t.text :subheadline
      t.string :cta_label
      t.bigint :contest_id
      t.boolean :active, default: false, null: false
      t.timestamps null: false
      t.string :background_style, default: "gradient", null: false
      t.string :badge

      t.index :contest_id
      t.index :slug, unique: true
    end

    add_foreign_key :landing_pages, :contests, on_delete: :nullify
  end
end
