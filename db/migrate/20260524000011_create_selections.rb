class CreateSelections < ActiveRecord::Migration[7.2]
  def change
    create_table :selections do |t|
      t.references :entry, null: false, foreign_key: true
      t.references :slate_matchup, null: false, foreign_key: true
      t.decimal :points, precision: 5, scale: 1
      t.string :slug
      t.timestamps null: false

      t.index [:entry_id, :slate_matchup_id], unique: true
      t.index :slug, unique: true
    end
  end
end
