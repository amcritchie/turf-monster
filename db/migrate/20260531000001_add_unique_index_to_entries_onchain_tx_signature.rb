class AddUniqueIndexToEntriesOnchainTxSignature < ActiveRecord::Migration[7.2]
  # Single-use guarantee for on-chain signatures (Lazarus audit #1/#8,
  # 2026-05-31). One finalized Solana signature must credit AT MOST ONE entry
  # row — otherwise a single real `enter_contest` tx can be replayed to
  # activate multiple paid entries. A partial unique index (NULLs allowed, so
  # cart / off-chain / legacy entries are unaffected) plus a model uniqueness
  # validation (Entry#onchain_tx_signature) back this.
  #
  # PROD PRE-FLIGHT: creating a unique index FAILS if duplicate non-null
  # signatures already exist. Before deploying, run on the target DB:
  #
  #   SELECT onchain_tx_signature, COUNT(*)
  #   FROM entries
  #   WHERE onchain_tx_signature IS NOT NULL
  #   GROUP BY onchain_tx_signature HAVING COUNT(*) > 1;
  #
  # If it returns rows, reconcile them first — duplicates indicate the
  # double-credit bug was already exercised. The `up` below performs that
  # check itself so the deploy aborts with actionable guidance instead of an
  # opaque PG::UniqueViolation.
  INDEX_NAME = "index_entries_on_onchain_tx_signature_unique".freeze

  def up
    dupes = connection.select_rows(<<~SQL)
      SELECT onchain_tx_signature, COUNT(*)
      FROM entries
      WHERE onchain_tx_signature IS NOT NULL
      GROUP BY onchain_tx_signature
      HAVING COUNT(*) > 1
    SQL

    if dupes.any?
      raise StandardError, <<~MSG
        Cannot add a unique index on entries.onchain_tx_signature:
        #{dupes.size} duplicate signature value(s) already exist. Reconcile
        these rows before deploying (see this migration's comment):
        #{dupes.map { |sig, n| "  #{sig} -> #{n} rows" }.join("\n")}
      MSG
    end

    add_index :entries, :onchain_tx_signature,
      unique: true,
      where: "onchain_tx_signature IS NOT NULL",
      name: INDEX_NAME
  end

  def down
    remove_index :entries, name: INDEX_NAME
  end
end
