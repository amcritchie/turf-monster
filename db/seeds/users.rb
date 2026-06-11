# Shared core user definitions — used by db/seeds.rb and e2e/seed.rb.
#
# Returns a hash of User objects keyed by username string.
# Uses find_or_create_by! for idempotency.

CORE_USERS = [
  { email: "alex@mcritchie.studio",    name: "Mr. McRitchie",   username: "mcritchie", role: "admin", wallet: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" },
  { email: "alexbot@mcritchie.studio", name: "Alex",            username: "alex",      role: "admin", wallet: "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" },
  { email: "mason@mcritchie.studio",   name: "Mason McRitchie", username: "mason",    wallet: "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" },
  { email: "mack@mcritchie.studio",    name: "Mack McRitchie",  username: "mack",     wallet: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds" },
  # turf@mcritchie.studio is the house account's STABLE identity — User.turf
  # keys on it (User::TURF_HOUSE_EMAIL), not the renameable username. The
  # reserved "turf" username is admin-exempt from the reserved-prefix mirror.
  { email: User::TURF_HOUSE_EMAIL,     name: "Turf Monster",    username: "turf",     role: "admin", wallet: "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo" },
].freeze

def seed_core_users!
  users = {}

  CORE_USERS.each do |data|
    # Passwordless (Lazarus audit #4): no password is set — email auth is
    # magic-link only. has_secure_password was removed, so `u.password=` no
    # longer exists; the password_digest column is dormant.
    user = User.find_or_create_by!(email: data[:email]) do |u|
      u.name     = data[:name]
      u.username = data[:username]
      u.role     = data[:role] || "user"
    end

    # Ensure fields are up to date on existing records
    user.update!(username: data[:username]) if user.username.blank?
    user.update!(role: data[:role]) if data[:role] && !user.send("#{data[:role]}?")

    # Set Phantom wallet address (real wallets, not managed)
    user.update!(
      web3_solana_address: data[:wallet],
      web2_solana_address: nil,
      encrypted_web2_solana_private_key: nil
    )

    users[data[:username]] = user
  end

  # Backfill managed wallets for users without any wallet
  User.where(web2_solana_address: nil, web3_solana_address: nil).find_each(&:generate_managed_wallet!)

  puts "  Created #{User.count} users"
  users
end
