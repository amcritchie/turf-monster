class AddChatEnabledToContests < ActiveRecord::Migration[7.2]
  def change
    # Per-contest kill switch for the chat room (admin-toggleable on the edit page).
    add_column :contests, :chat_enabled, :boolean, null: false, default: true
  end
end
