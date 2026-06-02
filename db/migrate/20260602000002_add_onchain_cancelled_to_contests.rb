class AddOnchainCancelledToContests < ActiveRecord::Migration[7.2]
  def change
    add_column :contests, :onchain_cancelled, :boolean, default: false, null: false
  end
end
