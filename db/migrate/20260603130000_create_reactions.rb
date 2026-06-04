class CreateReactions < ActiveRecord::Migration[7.2]
  def change
    create_table :reactions do |t|
      t.references :message, null: false, foreign_key: true
      t.references :user,    null: false, foreign_key: true
      t.string :emoji, null: false

      t.timestamps
    end

    # One reaction of a given emoji per user per message — clicking the same
    # emoji again toggles it off (see Reaction + MessagesController#toggle_reaction).
    add_index :reactions, [:message_id, :user_id, :emoji], unique: true,
              name: "index_reactions_uniqueness"
  end
end
