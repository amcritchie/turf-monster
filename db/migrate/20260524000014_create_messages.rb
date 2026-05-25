class CreateMessages < ActiveRecord::Migration[7.2]
  def change
    create_table :messages do |t|
      t.references :contest, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false
      t.datetime :hidden_at
      t.bigint :hidden_by_id
      t.timestamps null: false

      t.index [:contest_id, :created_at]
      t.index :hidden_by_id, where: "hidden_by_id IS NOT NULL"
    end
  end
end
