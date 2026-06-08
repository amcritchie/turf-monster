class CreateImpersonationLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :impersonation_logs do |t|
      t.integer :admin_id, null: false
      t.integer :target_user_id, null: false
      t.integer :action, null: false, default: 0     # enum enter:0 / exit:1
      t.string :ip
      t.string :user_agent
      t.string :reason
      # Audit-only: created_at, no updated_at (mirrors outbound_requests).
      t.datetime :created_at, null: false

      t.index [:admin_id, :created_at]
    end
  end
end
