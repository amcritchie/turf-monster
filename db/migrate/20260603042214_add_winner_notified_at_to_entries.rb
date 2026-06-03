class AddWinnerNotifiedAtToEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :entries, :winner_notified_at, :datetime
  end
end
