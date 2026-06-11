# Kickoff username claims — Track 1 (DB-only, no program changes).
#
# Idempotently claims the four kickoff usernames in the DB for the rows
# holding the matching wallet addresses (web3_solana_address first — these
# are Phantom-owned wallets — falling back to web2_solana_address).
#
# DB-only by design: Phantom-owned wallets can't be signed server-side, so
# this task NEVER pushes on-chain set_username. After a claim, the on-chain
# UserAccount PDA still holds the old name until the owner signs
# set_username via /account — or, for the house "turf" account, until the
# v0.25 admin path can initialize it (its name is a reserved prefix the
# program rejects from the user path, 6020 UsernameReserved).
#
# Username-taken conflicts are reported, not raised. Failures land in
# ErrorLog (backend discipline #1) and the task keeps going.
#
#   bin/rails admin:claim_usernames            # apply
#   DRY_RUN=1 bin/rails admin:claim_usernames  # report only, no writes
namespace :admin do
  desc "Idempotently claim the kickoff usernames (alex/mcritchie/mason/turf) in the DB by wallet (DRY_RUN=1 to preview)"
  task claim_usernames: :environment do
    kickoff = {
      "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" => "alex",
      "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" => "mcritchie",
      "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" => "mason",
      "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo" => "turf"
    }.freeze

    dry_run = ENV["DRY_RUN"].present?
    puts dry_run ? "admin:claim_usernames — DRY RUN (no writes)" : "admin:claim_usernames"
    puts

    onchain_owed = []

    kickoff.each do |wallet, username|
      label = "#{username.ljust(10)} #{wallet[0, 4]}…#{wallet[-4, 4]}"

      user = User.find_by(web3_solana_address: wallet) || User.find_by(web2_solana_address: wallet)
      unless user
        puts "  SKIP    #{label} — no user holds this wallet"
        next
      end

      if user.username&.casecmp?(username)
        puts "  OK      #{label} — already claimed by #{user.slug}"
        onchain_owed << [user, username]
        next
      end

      holder = User.where("LOWER(username) = ?", username.downcase).where.not(id: user.id).first
      if holder
        puts "  CONFLICT #{label} — \"#{username}\" is held by #{holder.slug}; #{user.slug} keeps \"#{user.username}\""
        next
      end

      if dry_run
        puts "  CLAIM   #{label} — would rename #{user.slug}: \"#{user.username}\" -> \"#{username}\""
        onchain_owed << [user, username]
        next
      end

      begin
        previous = user.username
        user.update!(username: username)
        puts "  CLAIMED #{label} — #{user.slug}: \"#{previous}\" -> \"#{username}\""
        onchain_owed << [user, username]
      rescue StandardError => e
        # Report-don't-raise: log to ErrorLog (the durable trace) and move on
        # so one bad row doesn't strand the remaining claims.
        ErrorLog.create!(
          message: "admin:claim_usernames failed for #{wallet}: #{e.class}: #{e.message}",
          inspect: { wallet: wallet, username: username, user: user.slug }.to_json,
          backtrace: Array(e.backtrace).first(10).to_json,
          target: user,
          target_name: user.slug
        )
        puts "  ERROR   #{label} — #{e.class}: #{e.message} (logged to ErrorLog)"
      end
    end

    puts
    puts "On-chain set_username still owed (DB-only task — chain state not checked):"
    if onchain_owed.empty?
      puts "  none"
    else
      onchain_owed.each do |user, username|
        path = user == User.turf ? "v0.25 admin init path (reserved name — program rejects the user path)" : "owner signs via /account"
        puts "  #{username.ljust(10)} #{user.slug} — #{path}"
      end
    end
  end
end
