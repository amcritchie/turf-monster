class CreateErrorLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :error_logs do |t|
      t.text :message, null: false
      t.text :inspect
      t.text :backtrace
      t.string :target_type
      t.bigint :target_id
      t.string :target_name
      t.string :parent_type
      t.bigint :parent_id
      t.string :parent_name
      t.string :slug
      t.timestamps null: false

      t.index :created_at
      t.index [:parent_type, :parent_id]
      t.index [:target_type, :target_id]
    end
  end
end
