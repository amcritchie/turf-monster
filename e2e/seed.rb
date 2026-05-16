# Seed test database for Playwright smoke tests.
# Run with: RAILS_ENV=test bin/rails runner e2e/seed.rb
#
# Idempotent — clears and recreates all test data.

puts "Seeding test database for Playwright..."

# Clear in dependency order
TransactionLog.delete_all
GeoSetting.delete_all
Selection.delete_all
Entry.delete_all
SlateMatchup.delete_all
Contest.delete_all
Slate.delete_all
Game.delete_all
Team.delete_all
User.delete_all

# Users (shared definitions across all seed files)
load Rails.root.join("db/seeds/users.rb")
users = seed_core_users!
alex  = users["alex"]
mason = users["mason"]
mack  = users["mack"]
# Note: alex's web3 wallet gets re-pointed to MOCK_PUBKEY_B58 at line ~175 below
# so the Phantom-mock auth flow finds an admin user with a complete profile.

# Teams — full World Cup 2026 Matchday 1 roster (48 teams)
TEAMS_DATA = [
  { name: "Mexico", short_name: "MEX", emoji: "🇲🇽", color_primary: "#006847", color_secondary: "#CE1126" },
  { name: "South Korea", short_name: "KOR", emoji: "🇰🇷", color_primary: "#CD2E3A", color_secondary: "#0047A0" },
  { name: "South Africa", short_name: "RSA", emoji: "🇿🇦", color_primary: "#007A4D", color_secondary: "#FFB612" },
  { name: "Czechia", short_name: "CZE", emoji: "🇨🇿", color_primary: "#D7141A", color_secondary: "#11457E" },
  { name: "Canada", short_name: "CAN", emoji: "🇨🇦", color_primary: "#FF0000", color_secondary: "#FFFFFF" },
  { name: "Bosnia and Herzegovina", short_name: "BIH", emoji: "🇧🇦", color_primary: "#003DA5", color_secondary: "#FCD116" },
  { name: "Qatar", short_name: "QAT", emoji: "🇶🇦", color_primary: "#8A1538", color_secondary: "#FFFFFF" },
  { name: "Switzerland", short_name: "SUI", emoji: "🇨🇭", color_primary: "#FF0000", color_secondary: "#FFFFFF" },
  { name: "Brazil", short_name: "BRA", emoji: "🇧🇷", color_primary: "#009C3B", color_secondary: "#FFDF00" },
  { name: "Morocco", short_name: "MAR", emoji: "🇲🇦", color_primary: "#C1272D", color_secondary: "#006233" },
  { name: "Haiti", short_name: "HAI", emoji: "🇭🇹", color_primary: "#00209F", color_secondary: "#D21034" },
  { name: "Scotland", short_name: "SCO", emoji: "🏴󠁧󠁢󠁳󠁣󠁴󠁿", color_primary: "#003399", color_secondary: "#FFFFFF" },
  { name: "United States", short_name: "USA", emoji: "🇺🇸", color_primary: "#002868", color_secondary: "#BF0A30" },
  { name: "Paraguay", short_name: "PAR", emoji: "🇵🇾", color_primary: "#D52B1E", color_secondary: "#0038A8" },
  { name: "Australia", short_name: "AUS", emoji: "🇦🇺", color_primary: "#00843D", color_secondary: "#FFCD00" },
  { name: "Türkiye", short_name: "TUR", emoji: "🇹🇷", color_primary: "#E30A17", color_secondary: "#FFFFFF" },
  { name: "Germany", short_name: "GER", emoji: "🇩🇪", color_primary: "#000000", color_secondary: "#DD0000" },
  { name: "Curaçao", short_name: "CUW", emoji: "🇨🇼", color_primary: "#003DA5", color_secondary: "#F9E814" },
  { name: "Ivory Coast", short_name: "CIV", emoji: "🇨🇮", color_primary: "#FF8200", color_secondary: "#009A44" },
  { name: "Ecuador", short_name: "ECU", emoji: "🇪🇨", color_primary: "#FFD100", color_secondary: "#003DA5" },
  { name: "Netherlands", short_name: "NED", emoji: "🇳🇱", color_primary: "#FF6600", color_secondary: "#FFFFFF" },
  { name: "Japan", short_name: "JPN", emoji: "🇯🇵", color_primary: "#000080", color_secondary: "#FFFFFF" },
  { name: "Sweden", short_name: "SWE", emoji: "🇸🇪", color_primary: "#006AA7", color_secondary: "#FECC02" },
  { name: "Tunisia", short_name: "TUN", emoji: "🇹🇳", color_primary: "#E70013", color_secondary: "#FFFFFF" },
  { name: "Belgium", short_name: "BEL", emoji: "🇧🇪", color_primary: "#ED2939", color_secondary: "#FAE042" },
  { name: "Egypt", short_name: "EGY", emoji: "🇪🇬", color_primary: "#CE1126", color_secondary: "#FFFFFF" },
  { name: "Iran", short_name: "IRN", emoji: "🇮🇷", color_primary: "#239F40", color_secondary: "#DA0000" },
  { name: "New Zealand", short_name: "NZL", emoji: "🇳🇿", color_primary: "#000000", color_secondary: "#FFFFFF" },
  { name: "Spain", short_name: "ESP", emoji: "🇪🇸", color_primary: "#AA151B", color_secondary: "#F1BF00" },
  { name: "Cape Verde", short_name: "CPV", emoji: "🇨🇻", color_primary: "#003893", color_secondary: "#CF2028" },
  { name: "Saudi Arabia", short_name: "KSA", emoji: "🇸🇦", color_primary: "#006C35", color_secondary: "#FFFFFF" },
  { name: "Uruguay", short_name: "URU", emoji: "🇺🇾", color_primary: "#5CBFEB", color_secondary: "#FFFFFF" },
  { name: "France", short_name: "FRA", emoji: "🇫🇷", color_primary: "#002395", color_secondary: "#FFFFFF" },
  { name: "Senegal", short_name: "SEN", emoji: "🇸🇳", color_primary: "#00853F", color_secondary: "#FDEF42" },
  { name: "Iraq", short_name: "IRQ", emoji: "🇮🇶", color_primary: "#007A33", color_secondary: "#FFFFFF" },
  { name: "Norway", short_name: "NOR", emoji: "🇳🇴", color_primary: "#EF2B2D", color_secondary: "#002868" },
  { name: "Argentina", short_name: "ARG", emoji: "🇦🇷", color_primary: "#75AADB", color_secondary: "#FFFFFF" },
  { name: "Algeria", short_name: "ALG", emoji: "🇩🇿", color_primary: "#006633", color_secondary: "#FFFFFF" },
  { name: "Austria", short_name: "AUT", emoji: "🇦🇹", color_primary: "#ED2939", color_secondary: "#FFFFFF" },
  { name: "Jordan", short_name: "JOR", emoji: "🇯🇴", color_primary: "#000000", color_secondary: "#007A3D" },
  { name: "Portugal", short_name: "POR", emoji: "🇵🇹", color_primary: "#006600", color_secondary: "#FF0000" },
  { name: "DR Congo", short_name: "COD", emoji: "🇨🇩", color_primary: "#007FFF", color_secondary: "#CE1021" },
  { name: "Uzbekistan", short_name: "UZB", emoji: "🇺🇿", color_primary: "#0099CC", color_secondary: "#1EB53A" },
  { name: "Colombia", short_name: "COL", emoji: "🇨🇴", color_primary: "#FCD116", color_secondary: "#003893" },
  { name: "England", short_name: "ENG", emoji: "🏴󠁧󠁢󠁥󠁮󠁧󠁿", color_primary: "#FFFFFF", color_secondary: "#CF081F" },
  { name: "Croatia", short_name: "CRO", emoji: "🇭🇷", color_primary: "#FF0000", color_secondary: "#FFFFFF" },
  { name: "Ghana", short_name: "GHA", emoji: "🇬🇭", color_primary: "#006B3F", color_secondary: "#FCD116" },
  { name: "Panama", short_name: "PAN", emoji: "🇵🇦", color_primary: "#DA121A", color_secondary: "#003893" },
]

teams = {}
TEAMS_DATA.each do |data|
  team = Team.create!(
    name: data[:name],
    short_name: data[:short_name],
    emoji: data[:emoji],
    color_primary: data[:color_primary],
    color_secondary: data[:color_secondary]
  )
  teams[data[:short_name]] = team
end

# Slate
slate = Slate.create!(
  name: "World Cup 2026",
  starts_at: 1.week.from_now
)

# Contest
contest = Contest.create!(
  name: "World Cup 2026",
  entry_fee_cents: 1900,
  status: "open",
  max_entries: 30,
  contest_type: "standard",
  starts_at: 1.week.from_now,
  slate: slate,
  rank: 100
)

# Matchday 1 games (24 games → 48 slate matchups)
MATCHDAY_1_GAMES = [
  { home: "MEX", away: "RSA" }, { home: "KOR", away: "CZE" },
  { home: "CAN", away: "BIH" }, { home: "USA", away: "PAR" },
  { home: "AUS", away: "TUR" }, { home: "QAT", away: "SUI" },
  { home: "BRA", away: "MAR" }, { home: "HAI", away: "SCO" },
  { home: "GER", away: "CUW" }, { home: "NED", away: "JPN" },
  { home: "CIV", away: "ECU" }, { home: "SWE", away: "TUN" },
  { home: "ESP", away: "CPV" }, { home: "BEL", away: "EGY" },
  { home: "KSA", away: "URU" }, { home: "IRN", away: "NZL" },
  { home: "FRA", away: "SEN" }, { home: "IRQ", away: "NOR" },
  { home: "ARG", away: "ALG" }, { home: "AUT", away: "JOR" },
  { home: "POR", away: "COD" }, { home: "ENG", away: "CRO" },
  { home: "GHA", away: "PAN" }, { home: "UZB", away: "COL" },
]

base_kickoff = 1.week.from_now
MATCHDAY_1_GAMES.each_with_index do |game_data, i|
  home = teams[game_data[:home]]
  away = teams[game_data[:away]]
  game_slug = "#{home.slug}-vs-#{away.slug}"

  Game.create!(
    home_team_slug: home.slug,
    away_team_slug: away.slug,
    kickoff_at: base_kickoff + i.hours,
    status: "pending"
  )

  slate.slate_matchups.create!(
    team_slug: home.slug,
    opponent_team_slug: away.slug,
    game_slug: game_slug,
    status: "pending"
  )
  slate.slate_matchups.create!(
    team_slug: away.slug,
    opponent_team_slug: home.slug,
    game_slug: game_slug,
    status: "pending"
  )
end

# Assign ranks and multipliers
matchups = slate.slate_matchups.includes(:team).to_a.sort_by { |m| m.team.name }
n = matchups.size
matchups.each_with_index do |matchup, i|
  rank = i + 1
  matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, n))
end

# Test-specific wallet overrides:
# Alex uses mock keypair (deterministic seed byte 1) so Playwright tests can sign.
# For devnet smoke tests, SOLANA_BOT_PUBKEY overrides Alex's wallet to Alex Bot's pubkey.
alex_wallet = ENV.fetch("SOLANA_BOT_PUBKEY", "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt")
alex.update!(web3_solana_address: alex_wallet)

# Clear encrypted keypairs so approve/deny tests don't trigger onchain withdrawals.
# Keep web2_solana_address so managed_wallet? stays true (needed for deposits).
User.update_all(encrypted_web2_solana_private_key: nil)

# Enable onchain path for the seeded contest (directOnchain check needs this)
contest.update!(onchain_contest_id: "MockContestPDA11111111111111111111111111111")

# Pre-seed a faucet transaction so admin transaction log tests work without real Solana
TransactionLog.create!(
  user: alex,
  transaction_type: "faucet",
  amount_cents: 10_00,
  direction: "credit",
  balance_after_cents: nil,
  description: "Devnet faucet $10.00",
  status: "completed"
)

# GeoSetting (disabled by default for most tests)
GeoSetting.create!(
  app_name: Studio.app_name,
  enabled: false,
  banned_states: GeoSetting::DEFAULT_BANNED_STATES
)

puts "Seeded: #{User.count} users, #{Team.count} teams, #{Slate.count} slates, #{Contest.count} contests, #{SlateMatchup.count} matchups, #{GeoSetting.count} geo_settings"
