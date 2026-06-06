class AddQuestNewsletterColumnsToUsers < ActiveRecord::Migration[7.2]
  def change
    # Quest progression markers (all one-way / nullable; presence = "done").
    add_column :users, :username_changed_at, :datetime    # first MANUAL username change → gates the 35-seed bonus
    add_column :users, :joined_email_list_at, :datetime    # newsletter subscribe (most-recent join)
    add_column :users, :left_email_list_at, :datetime      # newsletter unsubscribe (most-recent leave)

    # Per-user IP set for admin abuse review. Shape: { "1.2.3.4" => { "first" => iso8601, "last" => iso8601, "count" => N } }
    add_column :users, :ips, :jsonb, null: false, default: {}

    add_index :users, :joined_email_list_at
    add_index :users, :left_email_list_at
    add_index :users, :ips, using: :gin
  end
end
