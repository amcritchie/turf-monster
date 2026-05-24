# Audit H2 (2026-05-23): the payout_entry flow was removed in favor of the
# on-chain settle_contest path (which credits UserAccount.balance directly,
# leaving users to withdraw on their own schedule). The DB column it wrote
# to is no longer referenced anywhere — dropping it.
class RemovePayoutTxSignatureFromEntries < ActiveRecord::Migration[7.2]
  def change
    remove_column :entries, :payout_tx_signature, :string
  end
end
