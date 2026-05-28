# Seed dev (or test) database for Playwright specs.
# Run with: bin/rails runner e2e/seed.rb
#
# Playwright runs against the dev server (per playwright.config.js — see
# the "Dev server gotcha" note in CLAUDE.md), so this seed is normally
# invoked against the dev DB, not the test DB.
#
# Layering model (changed 2026-05-28):
#   1. Load db/seeds.rb (canonical). Idempotent — creates the 3 real
#      "World Cup 2026 Group N" slates with DraftKings-driven rankings,
#      72 real-kickoff Games, all 48 Teams. Re-running is safe.
#   2. Wipe test-volatile rows (Entry, Selection, Contest, SurvivorRound,
#      TransactionLog, GeoSetting, etc.) and User. Leaves Team / Slate /
#      SlateMatchup / Game intact — those belong to db/seeds.rb.
#   3. ALTER SEQUENCE users_id_seq → 1, then re-seed core users so the
#      inviter slugs referrals.spec.js hardcodes (mason-3, mack-4, turf-5)
#      stay stable across reseeds.
#   4. Build the e2e fixture contests (world-cup-2026, world-cup-survivor)
#      pointing at the canonical Group-1 slate. skip_onchain_callback so
#      they stay off-chain (real on-chain entry coverage is in
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
# Also seeds the 5 core users (alex/alex-bot/mason/mack/turf) but we
# wipe + redo them below for deterministic IDs.
load Rails.root.join("db/seeds.rb")

# ── Step 2: wipe test-volatile rows (preserve canonical data) ────────
# Each table below references User and/or contains state that bleeds
# between Playwright runs. Order matters for FK constraints.
puts "Resetting test-volatile state..."

Selection.delete_all
Entry.delete_all
SurvivorPick.delete_all
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
alex  = users["alex"]

# ── Step 4: build e2e fixture contests on the canonical Group-1 slate ─
slate = Slate.find_by!(name: "World Cup 2026 Group 1")

contest = Contest.new(
  name: "World Cup 2026",
  entry_fee_cents: 1900,
  status: "open",
  max_entries: 30,
  contest_type: "standard",
  starts_at: 1.week.from_now,
  slate: slate,
  rank: 100
)
# Stay off-chain — these Rails-only fixtures must not collide with the
# real on-chain Contest PDAs the operator creates via /contests/generator.
contest.skip_onchain_callback = true
contest.save!
contest.update_column(:slug, "world-cup-2026") unless contest.slug == "world-cup-2026"
contest.update!(onchain_contest_id: nil)

# ── World Cup Survivor ───────────────────────────────────────────────
# 8 global rounds; round 1 reuses Group-1's Matchday-1 games as its fixtures.
survivor_rounds = [
  [1, "Group Matchday 1", "group"],   [2, "Group Matchday 2", "group"],
  [3, "Group Matchday 3", "group"],   [4, "Round of 32", "knockout"],
  [5, "Round of 16", "knockout"],     [6, "Quarter-finals", "knockout"],
  [7, "Semi-finals", "knockout"],     [8, "Final", "knockout"]
].map do |num, rname, stage|
  SurvivorRound.create!(number: num, name: rname, stage: stage, status: "upcoming",
                        picks_lock_at: 2.weeks.from_now + num.days)
end

# Attach round 1 to the Group-1 Games (Matchday 1 fixtures).
group_1_team_slugs = slate.slate_matchups.pluck(:team_slug).uniq
Game.where(home_team_slug: group_1_team_slugs)
    .or(Game.where(away_team_slug: group_1_team_slugs))
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
#   1. Default (manual dev work): alex keeps the canonical admin wallet
#      seeded by db/seeds/users.rb (7ZDJp7FU…) — the real Phantom wallet
#      you connect with in the browser.
#
#   2. PLAYWRIGHT_SEED=true: Playwright's Phantom mock signs with
#      MOCK_PUBKEY_B58 (e2e/phantom-mock.js). Set this when seeding for
#      Playwright cold-starts (playwright.config.js's webServer.env).
#
#   3. SOLANA_BOT_PUBKEY=<pubkey>: explicit override (devnet-smoke
#      tests signing with Alex Bot's real key). Wins over both above.
#
# For local Playwright runs (reuseExistingServer = true) the swap is
# done at-test-time via globalSetup → POST /test/use_phantom_mock_admin.
PHANTOM_MOCK_WALLET = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze

alex_wallet =
  if (explicit = ENV["SOLANA_BOT_PUBKEY"]).present?
    explicit
  elsif ENV["PLAYWRIGHT_SEED"] == "true"
    PHANTOM_MOCK_WALLET
  else
    alex.web3_solana_address  # canonical wallet from db/seeds/users.rb
  end
alex.update!(web3_solana_address: alex_wallet)

# Clear encrypted keypairs so approve/deny tests don't trigger onchain withdrawals.
# Keep web2_solana_address so managed_wallet? stays true (needed for deposits).
User.update_all(encrypted_web2_solana_private_key: nil)

# Pre-seed a faucet TransactionLog so admin transaction log tests have something to render.
TransactionLog.create!(
  user: alex,
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

puts "Seeded: #{User.count} users, #{Team.count} teams, #{Slate.count} slates, " \
     "#{Contest.count} contests, #{SlateMatchup.count} matchups, " \
     "#{SurvivorRound.count} survivor rounds, #{GeoSetting.count} geo_settings"
