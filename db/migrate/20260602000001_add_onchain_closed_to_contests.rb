class AddOnchainClosedToContests < ActiveRecord::Migration[7.2]
  def change
    add_column :contests, :onchain_closed, :boolean, default: false, null: false
  end
end
