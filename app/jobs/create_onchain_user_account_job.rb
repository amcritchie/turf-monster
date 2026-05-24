# Eager on-chain UserAccount creation — enqueued from User after_commit at
# signup. The username's master record lives on-chain (turf-vault v0.14.0+),
# so the UserAccount PDA is created WITH the username at account-creation time.
#
# Idempotent: ensure_user_account no-ops if the PDA already exists, so a
# Sidekiq retry after a transient RPC failure is safe.
class CreateOnchainUserAccountJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.solana_connected?

    Solana::Vault.new.ensure_user_account(user.solana_address, username: user.username)
    Rails.logger.info "[username] onchain UserAccount ensured user=#{user.id} wallet=#{user.solana_address[0, 12]}..."
  rescue => e
    Rails.logger.error "[username] CreateOnchainUserAccountJob failed user=#{user_id}: #{e.class}: #{e.message}"
    raise
  end
end
