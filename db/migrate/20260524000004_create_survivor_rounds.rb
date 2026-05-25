class CreateSurvivorRounds < ActiveRecord::Migration[7.2]
  def change
    create_table :survivor_rounds do |t|
      t.integer :number, null: false
      t.string :name, null: false
      t.string :stage, default: "group", null: false
      t.datetime :picks_lock_at
      t.string :status, default: "upcoming", null: false
      t.string :slug
      t.timestamps null: false

      t.index :number, unique: true
      t.index :slug, unique: true
      t.index :status
    end
  end
end
