class CreateOutboundRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :outbound_requests do |t|
      t.string  :service, null: false       # "stripe" / "solana_rpc" / "moonpay"
      t.string  :method                     # HTTP verb or JSON-RPC method name
      t.string  :endpoint                   # URL or RPC method
      t.jsonb   :request_body,  default: {}
      t.jsonb   :response_body, default: {}
      t.integer :status_code                # HTTP status; nil for raised errors
      t.integer :duration_ms
      t.string  :error_class
      t.text    :error_message
      t.string  :source_type
      t.bigint  :source_id
      t.bigint  :user_id

      t.datetime :created_at, null: false   # immutable, no updated_at
    end

    add_index :outbound_requests, [:service, :created_at]
    add_index :outbound_requests, [:source_type, :source_id]
    add_index :outbound_requests, :error_class, where: "error_class IS NOT NULL"
    add_index :outbound_requests, :user_id, where: "user_id IS NOT NULL"
    add_index :outbound_requests, :created_at
  end
end
