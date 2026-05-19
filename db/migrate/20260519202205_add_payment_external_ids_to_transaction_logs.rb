class AddPaymentExternalIdsToTransactionLogs < ActiveRecord::Migration[7.2]
  # OPSEC-022: webhook idempotency was via JSONB scan
  # (TransactionLog.exists?(metadata: {stripe_session_id: ...})). Sidekiq's
  # at-least-once delivery + concurrent workers TOCTOU'd that check on
  # double-deliveries. Explicit columns + partial unique indexes move the
  # idempotency guarantee into the DB so the second concurrent insert
  # raises ActiveRecord::RecordNotUnique instead of duplicating.
  def change
    add_column :transaction_logs, :stripe_session_id, :string
    add_column :transaction_logs, :moonpay_tx_id, :string
    add_index :transaction_logs, :stripe_session_id,
              unique: true, where: "stripe_session_id IS NOT NULL",
              name: "index_transaction_logs_on_stripe_session_id_unique"
    add_index :transaction_logs, :moonpay_tx_id,
              unique: true, where: "moonpay_tx_id IS NOT NULL",
              name: "index_transaction_logs_on_moonpay_tx_id_unique"
  end
end
