class RenameContestStatusDraftToPending < ActiveRecord::Migration[7.2]
  def up
    execute "UPDATE contests SET status = 'pending' WHERE status = 'draft'"
    change_column_default :contests, :status, from: "draft", to: "pending"
  end

  def down
    execute "UPDATE contests SET status = 'draft' WHERE status = 'pending'"
    change_column_default :contests, :status, from: "pending", to: "draft"
  end
end
