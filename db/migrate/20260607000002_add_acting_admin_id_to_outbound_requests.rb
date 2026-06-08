class AddActingAdminIdToOutboundRequests < ActiveRecord::Migration[7.2]
  def change
    # OPSEC-046: when an admin is impersonating a user, stamp the REAL actor
    # behind a Stripe / Solana RPC call so the audit log attributes it to the
    # admin (Current.true_admin), not just the impersonated user (user_id).
    add_column :outbound_requests, :acting_admin_id, :integer
    add_index  :outbound_requests, :acting_admin_id, where: "acting_admin_id IS NOT NULL"
  end
end
