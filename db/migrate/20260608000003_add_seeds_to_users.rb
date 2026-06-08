class AddSeedsToUsers < ActiveRecord::Migration[7.2]
  def up
    # Cache of the user's on-chain seed total (the canonical value lives on the
    # UserAccount PDA). Maintained alongside `level` in User#update_level_from_seeds!
    # so admin lists can show + sort by seeds without an RPC per user.
    add_column :users, :seeds, :integer, default: 0, null: false
    add_index :users, :seeds
    # No backfill: `level` isn't maintained historically (it would floor to 0
    # anyway), and seeds is synced from the user's next on-chain navbar read
    # (ApplicationController#preload_navbar_solana_data → update_level_from_seeds!).
  end

  def down
    remove_column :users, :seeds
  end
end
