class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :name
      t.string :email
      t.string :username
      t.string :first_name
      t.string :last_name
      t.date :birth_date
      t.integer :birth_year
      t.string :password_digest, default: "", null: false
      t.string :provider
      t.string :uid
      t.string :role, default: "viewer"
      t.integer :level, default: 1, null: false
      t.string :web2_solana_address
      t.string :web3_solana_address
      t.text :encrypted_web2_solana_private_key
      t.bigint :invited_by_id
      t.string :slug
      t.timestamps null: false
      t.datetime :email_verified_at
      t.string :session_token
      t.boolean :payment_risk_flag, default: false, null: false
      t.string :reference
      t.datetime :frozen_at
      t.string :frozen_reason
      t.boolean :contest_entered, default: false, null: false
      t.integer :invitees_count, default: 0, null: false
      t.integer :invitees_in_contest_count, default: 0, null: false

      t.index "lower(username)", name: "index_users_on_lower_username", unique: true, where: "username IS NOT NULL"
      t.index :contest_entered, name: "index_users_on_contest_entered_true", where: "contest_entered = true"
      t.index :email, unique: true, where: "email IS NOT NULL"
      t.index :frozen_at, where: "frozen_at IS NOT NULL"
      t.index :invited_by_id
      t.index [:provider, :uid], unique: true, where: "provider IS NOT NULL"
      t.index :reference
      t.index :session_token
      t.index :slug, unique: true
      t.index :web2_solana_address, unique: true, where: "web2_solana_address IS NOT NULL"
      t.index :web3_solana_address, unique: true, where: "web3_solana_address IS NOT NULL"
    end

    add_foreign_key :users, :users, column: :invited_by_id
  end
end
