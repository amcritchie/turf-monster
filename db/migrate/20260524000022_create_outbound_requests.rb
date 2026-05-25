class CreateOutboundRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :outbound_requests do |t|
      t.string :service, null: false
      t.string :method
      t.string :endpoint
      t.jsonb :request_body, default: {}
      t.jsonb :response_body, default: {}
      t.integer :status_code
      t.integer :duration_ms
      t.string :error_class
      t.text :error_message
      t.string :source_type
      t.bigint :source_id
      t.bigint :user_id
      t.datetime :created_at, null: false

      t.index :created_at
      t.index :error_class, where: "error_class IS NOT NULL"
      t.index [:service, :created_at]
      t.index [:source_type, :source_id]
      t.index :user_id, where: "user_id IS NOT NULL"
    end
  end
end
