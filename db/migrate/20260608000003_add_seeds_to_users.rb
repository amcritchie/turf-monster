class AddSeedsToUsers < ActiveRecord::Migration[7.2]
  def up
    # Cache of the user's on-chain seed total (the canonical value lives on the
    # UserAccount PDA). Maintained alongside `level` in User#update_level_from_seeds!
    # so admin lists can show + sort by seeds without an RPC per user.
    add_column :users, :seeds, :integer, default: 0, null: false
    add_index :users, :seeds
    # Backfill the floor for each user's current level (level = seeds/100 + 1)
    # so the cache isn't all-zero until each user's next on-chain award refreshes it.
    execute "UPDATE users SET seeds = (level - 1) * 100"
  end

  def down
    remove_column :users, :seeds
  end
end
