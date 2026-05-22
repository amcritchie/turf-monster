# Backfill on-chain usernames for users created before turf-vault v0.14.0.
#
# New signups already get an on-chain UserAccount with the username via
# CreateOnchainUserAccountJob. This one-off covers pre-existing users:
# managed (custodial) wallets are set server-side; Phantom users must
# rename themselves from the account page (the server can't sign for them).
#
#   bin/rails usernames:backfill
namespace :usernames do
  desc "Backfill on-chain usernames for existing users (turf-vault v0.14.0+)"
  task backfill: :environment do
    vault = Solana::Vault.new
    ok = skipped = failed = 0

    User.where.not(username: nil).find_each do |user|
      unless user.solana_connected?
        skipped += 1
        next
      end

      addr = user.solana_address
      begin
        # Creates the PDA with the username if missing, or migrates an
        # old-layout account to v0.14.0 (username left empty).
        vault.ensure_user_account(addr, username: user.username)

        if user.phantom_wallet?
          puts "  ~ ##{user.id} #{user.username} — Phantom; account ensured, user must rename to set on-chain"
          skipped += 1
        else
          # Managed wallet — the server co-signs to guarantee the username is set.
          vault.set_username(addr, user.username, user_keypair: user.solana_keypair)
          puts "  ✓ ##{user.id} #{user.username}"
          ok += 1
        end
      rescue => e
        puts "  ✗ ##{user.id} #{user.username} — #{e.class}: #{e.message}"
        failed += 1
      end
    end

    puts "usernames:backfill done — #{ok} set, #{skipped} skipped, #{failed} failed"
  end
end
