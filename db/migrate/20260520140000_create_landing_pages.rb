class CreateLandingPages < ActiveRecord::Migration[7.2]
  def change
    create_table :landing_pages do |t|
      t.string  :name, null: false
      t.string  :slug
      t.string  :headline
      t.text    :subheadline
      t.string  :cta_label
      t.references :contest, foreign_key: { on_delete: :nullify }
      t.boolean :active, null: false, default: false

      t.timestamps
    end

    add_index :landing_pages, :slug, unique: true
  end
end
