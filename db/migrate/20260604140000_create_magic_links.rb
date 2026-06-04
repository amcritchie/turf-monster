class CreateMagicLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :magic_links do |t|
      t.string   :token,      null: false
      t.string   :email,      null: false
      t.string   :return_to
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :magic_links, :token, unique: true
    # supports the periodic sweep of expired/consumed rows
    add_index :magic_links, :expires_at
  end
end
