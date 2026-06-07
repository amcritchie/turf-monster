class AddFirstChatMessageAtToUsers < ActiveRecord::Migration[7.2]
  def change
    # Quest progression marker (one-way / nullable; presence = "done").
    # Set on the user's FIRST contest-chat message → gates the 25-seed
    # chat quest (v0.23). The on-chain SeedGrant[chat] PDA is the hard
    # once-ever guard; this column drives quest_step + the deferred backfill.
    add_column :users, :first_chat_message_at, :datetime
  end
end
