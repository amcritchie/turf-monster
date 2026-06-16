# Shared core user definitions — used by db/seeds.rb and e2e/seed.rb.
#
# Returns a hash of User objects keyed by username string.
# Adopts existing rows by email, wallet, or username for idempotency.

CORE_USERS = User::PARKED_IDENTITIES.map(&:dup).freeze

def seed_core_users!
  users = {}

  CORE_USERS.each do |data|
    # Passwordless (Lazarus audit #4): no password is set — email auth is
    # magic-link only. has_secure_password was removed, so `u.password=` no
    # longer exists; the password_digest column is dormant.
    user = User.find_by(email: data[:email]) ||
           User.find_by(web3_solana_address: data[:wallet]) ||
           User.find_by(username: data[:username]) ||
           User.new(email: data[:email])

    # Ensure fields are up to date on existing records
    user.assign_attributes(
      email: data[:email],
      name: data[:name],
      username: data[:username],
      role: data[:role] || "user"
    )

    # Set Phantom wallet address (real wallets, not managed)
    user.assign_attributes(
      web3_solana_address: data[:wallet],
      web2_solana_address: nil,
      encrypted_web2_solana_private_key: nil
    )
    user.save!

    users[data[:username]] = user
  end

  # Backfill managed wallets for users without any wallet
  User.where(web2_solana_address: nil, web3_solana_address: nil).find_each(&:generate_managed_wallet!)

  puts "  Created #{User.count} users"
  users
end
