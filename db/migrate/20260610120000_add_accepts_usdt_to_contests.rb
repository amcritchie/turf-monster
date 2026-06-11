# USDT entries (2026-06-10): contests created on-chain from this release on
# register an entry fee in BOTH accepted_currencies slots (0 = USDC, 1 = USDT)
# — see Contest#onchain_params. This flag mirrors that fact into the DB so the
# UI / ContestsController#prepare_entry can decide whether a contest can take
# a USDT entry without an RPC read of the on-chain fee schedule.
#
# Deliberately NOT backfilled: every existing contest was created with a zero
# USDT fee in the (immutable-after-create) entry_fee_by_currency array, so the
# program rejects currency_idx 1 with EntryFeeNotSet (6027). false is the
# truth for all of them; only new on-chain creations set it true.
class AddAcceptsUsdtToContests < ActiveRecord::Migration[7.2]
  def change
    add_column :contests, :accepts_usdt, :boolean, default: false, null: false
  end
end
