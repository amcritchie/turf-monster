class AddEmailVerifiedAtToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :email_verified_at, :datetime
  end
end
