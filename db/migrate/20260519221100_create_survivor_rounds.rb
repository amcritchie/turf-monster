class CreateSurvivorRounds < ActiveRecord::Migration[7.2]
  def change
    create_table :survivor_rounds do |t|
      t.integer :number, null: false
      t.string :name, null: false
      t.string :stage, null: false, default: "group"
      t.datetime :picks_lock_at
      t.string :status, null: false, default: "upcoming"
      t.string :slug

      t.timestamps
    end

    add_index :survivor_rounds, :number, unique: true
    add_index :survivor_rounds, :slug, unique: true
    add_index :survivor_rounds, :status
  end
end
