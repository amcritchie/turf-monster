class AddUniqueIndexToPendingTransactionsTxSignature < ActiveRecord::Migration[7.2]
  # Single-use guarantee for broadcast signatures (Lazarus audit #8 residual,
  # 2026-06-01). Mirrors the entries.onchain_tx_signature index: one finalized
  # tx_signature must back AT MOST ONE PendingTransaction. A partial unique
  # index (NULLs allowed, so unbroadcast pending rows are unaffected) plus a
  # model uniqueness validation (PendingTransaction#tx_signature) back this.
  #
  # NOTE: this is unrelated to the prior `slug` unique-index "treasury blocker"
  # (see PendingTransaction#name_slug) — that was a nil-id slug collision on a
  # different column; tx_signature has no index today.
  #
  # PROD PRE-FLIGHT: creating a unique index FAILS if duplicate non-null
  # signatures already exist. Before deploying, run on the target DB:
  #
  #   SELECT tx_signature, COUNT(*)
  #   FROM pending_transactions
  #   WHERE tx_signature IS NOT NULL
  #   GROUP BY tx_signature HAVING COUNT(*) > 1;
  #
  # The `up` below performs that check itself so the deploy aborts with
  # actionable guidance instead of an opaque PG::UniqueViolation.
  INDEX_NAME = "index_pending_transactions_on_tx_signature_unique".freeze

  def up
    dupes = connection.select_rows(<<~SQL)
      SELECT tx_signature, COUNT(*)
      FROM pending_transactions
      WHERE tx_signature IS NOT NULL
      GROUP BY tx_signature
      HAVING COUNT(*) > 1
    SQL

    if dupes.any?
      raise StandardError, <<~MSG
        Cannot add a unique index on pending_transactions.tx_signature:
        #{dupes.size} duplicate signature value(s) already exist. Reconcile
        these rows before deploying (see this migration's comment):
        #{dupes.map { |sig, n| "  #{sig} -> #{n} rows" }.join("\n")}
      MSG
    end

    add_index :pending_transactions, :tx_signature,
      unique: true,
      where: "tx_signature IS NOT NULL",
      name: INDEX_NAME
  end

  def down
    remove_index :pending_transactions, name: INDEX_NAME
  end
end
