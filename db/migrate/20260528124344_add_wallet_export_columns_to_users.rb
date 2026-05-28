# Self-custody export flow (task #11, Phase 2 — see User#self_custodied?).
#
# Adds two columns to users:
#   export_initiated_at — when the user clicked "Export wallet" after a
#     recent-password reauth. The wallet-export magic link was emailed at
#     this moment. Cleared on a fresh initiate so the most-recent link is
#     the only one that resolves.
#
#   self_custodied_at — when the user landed on the reveal page AND clicked
#     "I have my key". From this moment the server stops auto-signing on
#     their behalf: ContestsController#enter and Solana::Vault's managed
#     paths refuse to use the user's encrypted_web2_solana_private_key.
#     We do NOT delete the encrypted key yet (deferred decision — see
#     docs/SELF_CUSTODY.md / task #11 design notes); the column gates the
#     behavior, the key stays as a backup until we decide to sweep.
class AddWalletExportColumnsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :export_initiated_at, :datetime
    add_column :users, :self_custodied_at,   :datetime
    add_index  :users, :self_custodied_at
  end
end
