# Seed dev (or test) database for Playwright specs.
# Run with: bin/rails runner e2e/seed.rb
#
# Playwright runs against the dev server (per playwright.config.js), so this
# seed is normally invoked against the dev DB, not the test DB. See
# docs/LOCAL_STACK.md "Testing Notes".
#
# Layering model (changed 2026-05-28):
#   1. Load db/seeds.rb (canonical). Idempotent — creates the 3 real
#      "World Cup 2026 Group N" slates, the 6 knockout-stage World Cup slates
#      with bracket placeholders, and the "NFL 2026 Week N" slates.
#      Re-running is safe.
#   2. Wipe test-volatile rows (Entry, Selection, Contest, SurvivorRound,
#      TransactionLog, GeoSetting, etc.) and User. Leaves Team / Slate /
#      SlateMatchup / Game intact — those belong to db/seeds.rb.
#   3. ALTER SEQUENCE users_id_seq → 1, then re-seed core users so the
#      inviter slugs referrals.spec.js hardcodes (mason-3, mack-4, turf-5)
#      stay stable across reseeds.
#   4. Build the e2e fixture contests (world-cup-2026, world-cup-survivor).
#      The standard contest keeps its legacy slug but points at NFL Week 17,
#      which stays pickable through early January 2027. skip_onchain_callback so
#      the fixtures stay off-chain (real on-chain entry coverage is in
#      e2e/devnet-smoke.spec.js, which sets up its own fresh PDAs).
#
# Before this change e2e/seed.rb was destructive — it deleted Slate +
# SlateMatchup + Game + Team and rebuilt them with synthetic
# alphabetical-rank scoring. That clobbered any canonical slates the
# operator had built via `bin/rails db:seed`, leaving /contests/test1
# rendering placeholder scores. Now the canonical scoring survives every
# reseed and Playwright fixtures live alongside it.

puts "Seeding test database for Playwright (additive overlay)..."

# ── Step 1: canonical state via db/seeds.rb ──────────────────────────
# Loads idempotently. Creates / preserves teams, slates, matchups, games.
# Also seeds the 5 core users (mcritchie/alex/mason/mack/turf — the human
# operator is `mcritchie`, the server bot is `alex` after the 2026-06-02
# naming flip) but we
# wipe + redo them below for deterministic IDs.
load Rails.root.join("db/seeds.rb")

# ── Step 2: wipe test-volatile rows (preserve canonical data) ────────
# Each table below references User and/or contains state that bleeds
# between Playwright runs. Order matters for FK constraints.
puts "Resetting test-volatile state..."

SurvivorPick.delete_all          # FK → entries; must precede Entry.delete_all
Selection.delete_all              # FK → entries + slate_matchups
Entry.delete_all
# Sever games → survivor_rounds FK before nuking SurvivorRound rows. db/seeds.rb
# creates Games (and find_or_create_by leaves their survivor_round_id pointing
# at the previous run's SurvivorRound). Game rows themselves stay.
Game.update_all(survivor_round_id: nil)
SurvivorRound.delete_all
Contest.delete_all
TransactionLog.delete_all
GeoSetting.delete_all
StripePurchase.delete_all      if defined?(StripePurchase)
PendingTransaction.delete_all  if defined?(PendingTransaction)
OutboundRequest.delete_all     if defined?(OutboundRequest)
ErrorLog.delete_all            if defined?(ErrorLog)
Message.delete_all             if defined?(Message)
Goal.delete_all                if defined?(Goal)

# Users — wipe + reset the PK sequence so seeded users land at IDs 1..5.
# referrals.spec.js hardcodes `mason-3`, `mack-4`, `turf-5`.
User.delete_all
ActiveRecord::Base.connection.execute("ALTER SEQUENCE users_id_seq RESTART WITH 1")

# ── Step 3: re-seed core users (deterministic IDs) ───────────────────
load Rails.root.join("db/seeds/users.rb")
users = seed_core_users!
# The human operator — username `mcritchie` after the 2026-06-02 naming flip
# (was `alex`; the bare `alex` username now belongs to the server bot). This is
# the account whose Phantom wallet you connect with in the browser and the
# creator of the e2e fixture contest below.
human = users["mcritchie"]

# ── Step 4: build e2e fixture contests ────────────────────────────────
# Keep the legacy contest slug used throughout the specs, but use the late NFL
# slate/name so matchup buttons remain selectable for this QA cycle without
# rewriting canonical World Cup kickoff dates.
slate = Slate.find_by!(name: "NFL 2026 Week 17")

contest = Contest.new(
  name: "NFL 2026 Week 17",
  entry_fee_cents: 1900,
  status: "open",
  max_entries: 30,
  contest_type: "standard",
  starts_at: slate.first_game_starts_at || slate.starts_at || 1.week.from_now,
  slate: slate,
  rank: 100
)
# Stay off-chain — these Rails-only fixtures must not collide with the
# real on-chain Contest PDAs the operator creates via /contests/generator.
contest.skip_onchain_callback = true
contest.save!
contest.update_column(:slug, "world-cup-2026") unless contest.slug == "world-cup-2026"
contest.update!(onchain_contest_id: nil)

# Pin world-cup-2026 as the main contest so `/` always redirects here
# regardless of newer contests the operator creates via /contests/generator.
# Without this, SeasonConfig.main_contest picks the most-recently-created
# open contest — an operator-scaffolded test contest blocks Playwright's
# smoke specs that navigate to `/` expecting selection cards.
SeasonConfig.set_main_contest!(contest)

# ── World Cup Survivor ───────────────────────────────────────────────
# 8 global rounds; round 1 reuses the standard fixture slate's games.
survivor_rounds = [
  [1, "Group Matchday 1", "group"],   [2, "Group Matchday 2", "group"],
  [3, "Group Matchday 3", "group"],   [4, "Round of 32", "knockout"],
  [5, "Round of 16", "knockout"],     [6, "Quarter-finals", "knockout"],
  [7, "Semi-finals", "knockout"],     [8, "Final", "knockout"]
].map do |num, rname, stage|
  SurvivorRound.create!(number: num, name: rname, stage: stage, status: "upcoming",
                        picks_lock_at: 2.weeks.from_now + num.days)
end

# Attach round 1 to the standard fixture games.
fixture_team_slugs = slate.slate_matchups.pluck(:team_slug).uniq
Game.where(home_team_slug: fixture_team_slugs)
    .or(Game.where(away_team_slug: fixture_team_slugs))
    .update_all(survivor_round_id: survivor_rounds.first.id)

survivor = Contest.new(
  name: "World Cup Survivor",
  game_type: "world_cup_survivor",
  contest_type: "survivor_wc_free",
  entry_fee_cents: 0,
  max_entries: 59,
  status: "open",
  # Backdated so /  redirect picks the standard contest, not survivor.
  created_at: 1.day.ago
)
survivor.skip_onchain_callback = true
survivor.save!
survivor.update_column(:slug, "world-cup-survivor") unless survivor.slug == "world-cup-survivor"

# ── Wallet overrides ─────────────────────────────────────────────────
#
#   1. Default (manual dev work): the human (mcritchie) keeps the canonical admin wallet
#      seeded by db/seeds/users.rb (7ZDJp7FU…) — the real Phantom wallet
#      you connect with in the browser.
#
#   2. PLAYWRIGHT_SEED=true: Playwright's Phantom mock signs with
#      MOCK_PUBKEY_B58 (e2e/phantom-mock.js). Set this when seeding for
#      Playwright cold-starts (playwright.config.js's webServer.env).
#
#   3. SOLANA_BOT_PUBKEY=<pubkey>: explicit override (devnet-smoke
#      tests signing with the server bot's real key — the bot is named "Alex"
#      after the 2026-06-02 naming flip). Wins over both above.
#
# For local Playwright runs (reuseExistingServer = true) the swap is
# done at-test-time via globalSetup → POST /test/use_phantom_mock_admin.
PHANTOM_MOCK_WALLET = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze

human_wallet =
  if (explicit = ENV["SOLANA_BOT_PUBKEY"]).present?
    explicit
  elsif ENV["PLAYWRIGHT_SEED"] == "true"
    PHANTOM_MOCK_WALLET
  else
    human.web3_solana_address  # canonical wallet from db/seeds/users.rb
  end
human.update!(web3_solana_address: human_wallet)

# Clear encrypted keypairs so approve/deny tests don't trigger onchain withdrawals.
# Keep web2_solana_address so managed_wallet? stays true (needed for deposits).
User.update_all(encrypted_web2_solana_private_key: nil)

# Pre-seed a faucet TransactionLog so admin transaction log tests have something to render.
TransactionLog.create!(
  user: human,
  transaction_type: "faucet",
  amount_cents: 10_00,
  direction: "credit",
  balance_after_cents: nil,
  description: "Devnet faucet $10.00",
  status: "completed"
)

# GeoSetting (disabled by default; geo specs flip it via /admin/geo).
GeoSetting.create!(
  app_name: Studio.app_name,
  enabled: false,
  banned_states: GeoSetting::DEFAULT_BANNED_STATES
)

# ── Multi-week slate (NFL Weeks 1-3) ─────────────────────────────────
# A Slate is a POOL OF GAMES: this one holds three weeks, so each team appears
# three times and is ranked on its SUMMED expected points. Backs
# e2e/multi_week_slate.spec.js. Guarded on the three weeks existing.
span_source_weeks = Slate.where(name: ["NFL 2026 Week 1", "NFL 2026 Week 2", "NFL 2026 Week 3"]).to_a
if span_source_weeks.size == 3
  span_slate = Slate.find_or_create_by!(name: "NFL 2026 Weeks 1-3") { |s| s.slug = "nfl-2026-weeks-1-3" }
  span_slate.slate_matchups.destroy_all

  span_source_weeks.each do |week_slate|
    week_slate.slate_matchups.each do |week_matchup|
      span_slate.slate_matchups.create!(
        team_slug: week_matchup.team_slug,
        opponent_team_slug: week_matchup.opponent_team_slug,
        game_slug: week_matchup.game_slug,
        dk_goals_expectation: week_matchup.dk_goals_expectation,
        status: "pending"
      )
    end
  end

  span_rankings = span_slate.team_rankings
  span_slate.slate_matchups.find_each do |span_matchup|
    ranking = span_rankings[span_matchup.team_slug]
    span_matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score]) if ranking
  end
end

puts "Seeded: #{User.count} users, #{Team.count} teams, #{Slate.count} slates, " \
     "#{Contest.count} contests, #{SlateMatchup.count} matchups, " \
     "#{SurvivorRound.count} survivor rounds, #{GeoSetting.count} geo_settings"
