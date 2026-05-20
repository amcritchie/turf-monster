class CreateMessages < ActiveRecord::Migration[7.2]
  def change
    create_table :messages do |t|
      t.references :contest, null: false, foreign_key: true, index: false
      t.references :user,    null: false, foreign_key: true
      t.text     :body,      null: false
      t.datetime :hidden_at               # set when an admin hides the message (soft-delete)
      t.bigint   :hidden_by_id            # admin User who hid it (audit trail)

      t.timestamps
    end

    # Primary query: a contest's messages in posted order.
    add_index :messages, [:contest_id, :created_at]
    # Sparse — only the handful of moderated messages.
    add_index :messages, :hidden_by_id, where: "hidden_by_id IS NOT NULL"
  end
end
