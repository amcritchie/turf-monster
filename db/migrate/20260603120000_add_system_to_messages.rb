class AddSystemToMessages < ActiveRecord::Migration[7.2]
  def change
    # System/announcement messages (e.g. "🎉 crispy-apple joined the contest")
    # are authored by the joining user but rendered as a centered, avatar-less
    # announcement line rather than a typed chat bubble. Default false = a
    # normal user-typed message.
    add_column :messages, :system, :boolean, default: false, null: false

    # Powers the "announce a join only once per user per contest" idempotency
    # check (Message.join_announced?). Partial index — only system rows matter.
    add_index :messages, [:contest_id, :user_id, :system],
              where: "system",
              name: "index_messages_on_contest_user_system"
  end
end
