# Turf Monster (turf-monster)

Peer-to-peer sports pick'em game focused on team matchup selections with Turf Scores for the World Cup.

## Topic Files

Load these when working on specific areas:

| File | When to read |
|------|-------------|
| `docs/AUTH.md` | Authentication, account management, admin authorization, SSO |
| `docs/SIGNUP_FLOWS.md` | Sign-up flow sequence diagrams (Phantom / Google / manual) |
| `docs/SOLANA.md` | Solana integration, wallet types, onchain flows, rake tasks |
| `docs/FORMULAS.md` | Scoring formulas, slate system, Chart.js patterns |
| `docs/UI_PATTERNS.md` | Branding, theme colors, matchup grid, hold button, animations |
| `docs/world_cup_2026.md` | World Cup format, groups, matchday structure |

## Game Rules

- Each contest has a set of **matchups** — team/opponent pairs with Turf Scores based on rank
- Players select **6 matchups** per entry
- Each selection is scored: **team goals x turf_score**
- Entry score = sum of all selection scores
- Entries ranked by score DESC; ties get the same rank
- **Contest tiers** (GTM 2026-05-17, all $19 entry fee, defined in `Contest::FORMATS`):

  | Tier | Entries | 1st | 2nd | 3rd-5th | 6th-9th | Pot | Margin |
  |------|--------:|----:|----:|--------:|--------:|----:|-------:|
  | `tiny` | 3 | $45 | — | — | — | $57 | $12 (21%) |
  | `small` | 5 | $75 | — | — | — | $95 | $20 (21%) |
  | `medium` | 9 | $100 | $40 | — | — | $171 | $31 (18%) |
  | `standard` | 29 | $300 | $50 | $50 each | — | $551 | $51 (9%) |
  | `large` | 99 | $1,000 | $100 | $100 each | $100 each | $1,881 | $81 (4%) |

  Ties split evenly within their rank's payout amount.
- Max 3 entries per user per contest (different selection combos required)
- Entry fee deducted from user balance on confirm

### World Cup Survivor (parallel format, `game_type: :world_cup_survivor`)

Single-elimination survivor pick (one team per round, must win to advance). Separate contest format from Turf Totals; defined alongside the tier table in `Contest::FORMATS`.

| Tier | Max entries | Entry fee | Winner takeall |
|------|------------:|----------:|---------------:|
| `survivor_wc_paid` | 59 | $19 | $1,000 |
| `survivor_wc_free` | 59 | $0  | $200 |

- Max 1 entry per user per Survivor contest (vs 3 for Turf Totals).
- `picks_required = 0` at the entry level — picks are resolved per `SurvivorRound`, not at confirm time.
- Lifecycle adds a `grade_round` admin action that scores the current round + marks `SurvivorPick.result` as `survived` or `eliminated`. See `Entry#survivor?` / `Entry#eliminated?` predicates.

## Contest Lifecycle

```
pending → open → locked → settled
```

- **pending**: Contest created, not yet accepting entries (was `draft` pre-v0.4.1 of audit; Rails 7 reserves `:new` so `pending` was chosen instead)
- **open**: Players can submit entries (toggle selections, hold-to-confirm)
- **locked**: No new entries, waiting for game results
- **settled**: All games scored, entries ranked, payouts distributed

### Contest Targeting (root page)

- Root (`/`) redirects to the most recent open/locked/settled contest's **lobby** page (`/c/:id/lobby`)
- Falls back to `/contests` index if no eligible contest exists
- `Contest.ranked` scope and `Contest.target` still exist but root no longer uses them
- `load_contest_board_data` — shared private method used by `lobby` and `show` actions

### Lobby Page (`/c/:id/lobby`)

Mobile-first contest preview/info page. Renders inline matchup board or leaderboard depending on user state.

**Sections:**
1. Hero banner (Active Storage image or gradient fallback) + creator avatar + Solana PDA overlay (SE corner)
2. Contest info: name, creator, lock time, stats row (prizes, entry fee, entries count, "+ Add Nth Entry" link)
3. Conditional cards: seeds+share (entered users) or info cards (new users)
4. Inline matchup board (not entered) or compact leaderboard (entered)
5. Admin section (Fill/Lock/Grade + Simulate buttons) — admin only, unsettled contests
6. Contest selector — other open/locked contests

**Partial `compact` flag**: Both `_turf_totals_board` and `_turf_totals_leaderboard` accept `compact: true` to hide admin buttons, onchain details, and info cards when rendered inline from the lobby.

### Admin Actions (contest show page + navbar)

- **Fill Contest** — generates random entries (6 random matchups each). Cycles through seeded users. Deduplicates against existing entries.
- **Lock Contest** — transitions open → locked
- **Jump** — simulates all game results and settles the contest in one click
- **Grade Contest** — scores entries based on game results, assigns ranks, distributes payouts. Settlement creates a `PendingTransaction` for 2-of-3 multisig cosigning (see Treasury).
- **Reset** (navbar) — clears all entries/selections, resets games, sets contest back to open

### Key Model Methods

- `Contest#fill!(users:)` — random entries, 6 random matchups each, no duplicate combos
- `Contest#jump!` — simulate game results + grade in one transaction
- `Contest#grade!` — score entries → rank → distribute payouts → settle. Persists `rank` and `payout_cents` on each entry.
- `Contest#reset!` — destroy entries, reset game scores, reopen contest
- `Entry#confirm!` — validates exactly 6 selections, checks for locked games, deducts entry fee, cart → active

## Dev Server

- **Port 3001** — `bin/rails server -p 3001`
- `bin/dev` starts web (port 3001), CSS watcher, and Sidekiq worker via Procfile.dev
- **Redis required** — `brew services start redis` before running. Sidekiq connects to `redis://localhost:6379/0` by default.

## Deployment

- **Heroku app**: `turf-monster`
- **URL**: https://turf.mcritchie.studio
- **Database**: Heroku Postgres (essential-0)
- **Redis**: Heroku Redis mini (`redis-clear-09691`) — `REDIS_URL` set automatically
- **Deploy**: `bin/deploy` — wraps `git push heroku main` + auto-migrates + pre-flight checks (IDL hash drift, `SKIP_IDL_VERIFICATION` set, Stripe test-mode key, dirty tree, failing tests). `bin/deploy --help` for options. **One-time mainnet first deploy**: follow `MAINNET_LAUNCH.md` instead.
- **Env vars** (currently set on Heroku): `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, `DATABASE_URL` (auto), `REDIS_URL` (auto), `RAILS_SERVE_STATIC_FILES`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `RESEND_API_KEY`, `MAILER_FROM`, `MANAGED_WALLET_ENCRYPTION_KEY`, `EXPECTED_IDL_HASH`, `SOLANA_PROGRAM_ID`. See `.env.example` for the full documented set (including `SOLANA_ADMIN_KEY` / `SOLANA_RPC_URL` for local dev).

## Tech Stack

- Ruby 3.1 / Rails 7.2 / PostgreSQL 14
- Tailwind CSS via `tailwindcss-rails` gem (compiled, not CDN)
- Alpine.js via CDN for interactivity
- ERB views, import maps, no JS frameworks
- bcrypt + Google OAuth + Solana wallet auth (Phantom)
- **Sidekiq** + Redis for background jobs (web UI at `/admin/jobs`, admin-only)
- **Studio engine gem** — `gem "studio-engine", git: "https://github.com/amcritchie/studio-engine.git"`
- **SolanaStudio gem** — `gem "solana-studio", git: "https://github.com/amcritchie/solana-studio.git"`

## JS Modules (importmap)

- `base58` — canonical Base58 encoder/decoder (`encodeBase58`, `decodeBase58`). Single source of truth — all Solana modules use this. Loaded before other Solana modules. Attached to `window` for backward compatibility.
- `wallet_provider` — wallet abstraction layer (PhantomProvider, KeypairProvider, registry). Uses `window.encodeBase58` from base58.js.
- `solana_utils` — shared Solana/crypto utilities: `lockedFetch`, `refreshBalance`, `refreshBalanceDelayed`, `CONFETTI_COLORS`. Attached to `window` for backward compatibility.
- `solana_errors` — Solana error message parser (`parseSolanaError`).
- `solana_stores` — Alpine.js wallet watcher store (detects wallet switches, silent re-auth).
- `phantom_deeplink` — Phantom deep link protocol for mobile browsers.
- `cosign` — `cosignTransaction()` for admin treasury co-signing via Phantom. Reads RPC URL from `#cosign-config` data attribute.

> `fireSuccessConfetti()` lives in `solana_utils.js`, not a separate `wallet_connect` module (the file `app/javascript/wallet_connect.js` exists but is not pinned in `config/importmap.rb` — flag for cleanup).
- `turf_board` — `shrinkTeamNames()` utility for auto-sizing long team names.

### JSON Config Pattern (ERB→JS data passing)

When inline scripts depend on ERB-interpolated values, use a JSON config block:

```erb
<script type="application/json" id="board-config">
<%= { key: @value, nested: { a: 1 } }.to_json.html_safe %>
</script>
```

The JS reads it: `var cfg = JSON.parse(document.getElementById('board-config').textContent);`

### Inline JS that MUST stay inline (Alpine timing constraint)

Alpine's `defer` script evaluates `x-data` attributes BEFORE importmap modules load. Any function referenced in `x-data` must be defined inline (not in a module):

- `solanaWalletConnect()` — full wallet connect component, inline in layout `application.html.erb`
- `selectionBoard()` — full matchup board component, inline in `_turf_totals_board.html.erb` partial. Reads config from `#board-config` JSON element.
- `solanaModal` Alpine store — inline in layout, registered on `alpine:init`
- `walletProvider` stub — minimal stub for `isAvailable()`/`isMobile()`/`detect()`, overwritten by full module on import

## Studio Engine

Shared code from [studio engine](https://github.com/amcritchie/studio-engine). Configured in `config/initializers/studio.rb`.

**From the engine:** `Studio::ErrorHandling`, `ErrorLog` model, `Sluggable` concern, auth controllers, error log views, theme system, `_theme_toggle_morph` partial (spinner/toggle swap), `showNavSpinner`/`hideNavSpinner` globals, **`Studio::S3`** + **`Studio::ImageCache`** + `ImageCache` model.

**Overridden locally:** `sessions/new.html.erb`, `registrations/new.html.erb`, `omniauth_callbacks_controller.rb` (merge support), `layouts/_navbar.html.erb` (app-specific nav links, mobile sub-navbar with duplicate gear+moon fix). SSO "Continue as X" partial intentionally not overridden — feature disabled at the session-cookie layer (see `docs/AUTH.md` SSO Satellite Role).

**Routes:** `Studio.routes(self)` draws `/login`, `/signup`, `/logout`, `/sso_continue`, `/sso_login`, `/auth/:provider/callback`, `/error_logs`, `/admin/theme`.

**S3 config:** `config.s3_bucket_prefix = "turf-monster"` overrides the engine default — bucket resolves to `turf-monster-dev` (dev/test) or `turf-monster-production` (prod). All 4 studio buckets are public-read; `mcritchie-studio-dev` has a 90-day GLACIER_IR archive rule. AWS creds via shared `op://` refs in `/Users/alex/projects/.env` (Heroku needs `heroku config:set AWS_*` separately — not yet done). `image_caches` table created 2026-04-29; not yet used by any model in this app.

**Updating:** After changes to the studio repo, run `bundle update studio-engine` here.

## Architecture

- Money stored in cents, displayed in dollars via `dollars()` helper
- **6 selections per entry** — `Contest#picks_required` returns 6. All views use this dynamically. Max 3 entries per user per contest (`Contest#max_entries_per_user`).
- **Balance system**: On-chain USDC is the single source of truth. All balance reads come from on-chain wallet via `display_balance` helper. Entry fees transfer USDC on-chain via `Vault#transfer_from_user`.
- **Slug-based foreign keys**: Teams, Games, Players use slug columns as FKs (e.g. `team_slug`, `home_team_slug`). Associations use `foreign_key: :*_slug, primary_key: :slug`.
- **Turf Score formula**: `1.0 + 3.0 * ln(rank) / ln(N)` — x1.0 at rank 1 to x4.0 at rank N. Centralized on `SlateMatchup.turf_score_for(rank, n)`.
- **Seeds system**: 65 seeds per entry on-chain. No DB columns. See `docs/SOLANA.md`.
- **Entry tokens**: on-chain `EntryTokenAccount` PDAs (turf-vault v0.9.0+). DB `stripe_purchases` is audit-only. See `Solana::Vault#list_entry_tokens` and `app/controllers/admin/free_entries_controller.rb`.
- Entry slug includes `id` — requires `after_create` callback
- Every page shows JSON debug block of its primary record

## Models

- **User** — name, username, email (nullable), solana_address, wallet_type, role, slug. Balance is on-chain USDC. See `docs/AUTH.md`.
- **Contest** — name, tagline, entry_fee_cents, status, max_entries, rank, season_id (OPSEC-023), slate association, onchain fields, slug. `belongs_to :user` (creator, optional). `has_one_attached :contest_image` (Active Storage). Helpers: `lock_time_display`, `active_entry_count`, `locks_at` (alias for `starts_at`). Contest's matchups come from `SlateMatchup` via the associated `Slate` — there is no separate `ContestMatchup` model.
- **Entry** — user + contest, score, status (cart/active/complete/abandoned), rank, payout_cents, onchain fields, slug (includes id)
- **Selection** — joins entry + slate_matchup (unique pair)
- **Team** — name, short_name, emoji, color_primary/secondary, slug
- **Game** — home_team + away_team via slug FKs, kickoff_at, status, scores, slug
- **Player** — name, position, jersey_number, team via slug FK, slug
- **Slate** — formula variables (7 nullable floats), 3-tier resolution. See `docs/FORMULAS.md`.
- **SlateMatchup** — team/opponent/game via slug FKs, rank, turf_score, dk_goals_expectation. Formula class methods (`turf_score_for`, `goals_distribution_for`).
- **PendingTransaction** — multisig treasury TXs awaiting cosign. Fields: tx_type, serialized_tx, status (pending/confirmed/expired/failed), polymorphic target, initiator/cosigner addresses, tx_signature, metadata (jsonb), slug.
- **GeoSetting** — admin geofencing config
- **TransactionLog** — admin onchain transaction audit
- **ErrorLog** — polymorphic, from engine

### Auth / session / audit

- **Current** — `ActiveSupport::CurrentAttributes`. Attributes: `user`, `outbound_source`. Request- and Sidekiq-job-scoped (auto-resets). Set by `ApplicationController#set_current_context` and jobs/services to flow `user` + polymorphic domain object through the logging layers (especially `OutboundRequest`). No slug.
- **SessionContext** — PORO (NOT ActiveRecord). Inputs: `user`, `@onchain_session` (boolean — true when authenticated via a live Phantom signature this session, separate from account-level `phantom_linked?`). MODES: `:guest` / `:web2` / `:web3`. Methods: `mode`, `guest?`, `web2?`, `web3?`, `logged_in?`, `phantom_linked?`, `user_id`, `address`, `to_h` (camelCase JSON), `as_json`. Canonical single source of truth for viewer's auth/wallet state — built per-request by `ApplicationController#wallet_context`, serialized into the `#session-context` JSON block, consumed by `$store.session` in Alpine. No slug.
- **OutboundRequest** — `service` (string: `stripe` / `solana_rpc` / `moonpay`), `status_code`, `error_class`, `created_at` (manual, no `updated_at`). `belongs_to :source` (polymorphic, optional), `belongs_to :user` (optional). Scopes: `recent`, `for_service`, `failed`, `successful`. Predicates: `failed?`, `successful?`. Immutable audit log of every Stripe + Solana RPC call (set via `Stripe::Instrumentation` + prepended `Solana::ClientLogger`); retention sweeper trims 90d ok / 180d failed. No slug.

### Web2 commerce + funnel

- **StripePurchase** — `Sluggable` (randomized slug). `stripe_session_id` (unique), `quantity`, `price_cents`, `status` (enum: pending/minted/refunded/failed), `mint_tx_signatures` (JSON array — incremental persistence for crash recovery), `minted_at`, `refunded_at`, `refund_reason`, `pack_id`. `belongs_to :user`. `PACKS` constant: `single` (1 token, $19), `trio` (3 tokens, $49), `test_trio` (3 tokens, $5 — scaffold-gated by `ENABLE_TEST_SCAFFOLDING`). Methods: `mark_minted!(signatures)`, `mark_refunded!(reason:)`, `tx_signatures`, `StripePurchase.available_packs`. Audit log for Stripe token purchases — on-chain tokens themselves live as `EntryTokenAccount` PDAs in turf-vault.
- **LandingPage** — `Sluggable` (`before_validation :set_slug`). `slug` (unique), `name`, `active` (boolean), `background_style` (enum: gradient/blobs/circles), `cta_label`, `contest_id` (FK, optional). `belongs_to :contest` (optional). Scope: `active`. Methods: `cta_label_display`, `background_partial`, `signup_count` (counts users via `?ref=` attribution). Marketing funnel splash pages with animated backgrounds; slug can be explicit (stable across name edits) or derived from name.

### Real-time + game-day state

- **Message** — `body` (max 500 chars), `hidden_at` (soft-delete timestamp), `hidden_by_id` (admin FK). `belongs_to :contest, :user`. Callbacks: `after_create_commit :broadcast_new_message` (Turbo Stream prepend via ActionCable), `after_update_commit :broadcast_removal` (on `hidden_at` change). Scope: `visible`. Methods: `hidden?`, `hide!(admin)`, `Message.recent_for(contest, limit:)`. Real-time contest chat — admin can soft-delete with `hidden_at` audit trail. No slug. See `docs/UI_PATTERNS.md` § ActionCable.
- **Goal** — `Sluggable` (`after_create :update_slug_with_id`). `game_slug` (FK), `team_slug` (FK), `player_slug` (FK, optional). `belongs_to :game, :team, :player` (slug FKs). Callbacks: `after_create :refresh_game_scores`, `after_destroy :refresh_game_scores`. `name_slug` = `"goal-#{id}"`. Records individual team goals in a Game; triggers game score recompute on create/destroy.

### Seasons + Survivor

- **SeasonConfig** — `Sluggable` with hardcoded `name_slug = "season-config"`. `current_season_id` (int, ≥0). Class methods: `SeasonConfig.current`, `SeasonConfig.current_season_id`, `SeasonConfig.set_current!(season_id)`. Rails-side singleton pointer to the active on-chain `Season` PDA in turf-vault.
- **SurvivorRound** — `Sluggable`. `number` (unique), `name`, `stage` (enum: group/knockout), `status` (enum: upcoming/locked/completed), `picks_lock_at` (nullable). `has_many :games` (dependent: nullify), `has_many :survivor_picks` (dependent: destroy). Scopes: `ordered`. Methods: `SurvivorRound.current` (earliest unlocked), `group_stage?`, `knockout?`, `picks_locked?`. World Cup Survivor tournament round tracker.
- **SurvivorPick** — `Sluggable`. `result` (enum: pending/survived/eliminated), `entry_id` (FK), `survivor_round_id` (FK), `team_slug` (FK). `belongs_to :entry, :survivor_round, :team` (Team via slug FK). Validations: unique `[survivor_round_id, entry_id]` (one pick per entry per round) and unique `[team_slug, entry_id]` (can't reuse a team across rounds). `name_slug` = `"#{entry.slug}-round-#{survivor_round.number}"`. World Cup Survivor per-entry, per-round team pick.

## Error Logging

Every write action MUST use `rescue_and_log` with target/parent context. See top-level `CLAUDE.md` for full pattern docs.

- ContestsController: toggle_selection, enter, clear_picks → `target: entry, parent: @contest`. Grade, fill, lock, jump, reset, update → `target: @contest`.
- AccountsController: update, unlink_google, change_password → `target: current_user`

## Routes

### Public
- `/` — contests#world_cup (redirects to most recent contest lobby)
- `/c/:id/lobby` — contests#lobby (mobile-first contest preview, inline board/leaderboard)
- `/contests` — contests#index (card grid, newest first, banner images, "My Contests" + "New Contest" buttons)
- `/contests/:id` — contest show (full leaderboard + admin actions)
- `/contests/:id/edit` — admin contest editor (name, tagline, status, rank, image, locks_at)
- `/teams`, `/teams/:slug` — team index/show
- `/games` — games index
- `/faucet` — public faucet page (GET marketing, POST mint USDC)
- `/geo/check` — geo detection JSON (no auth)

### Contest Actions (POST)
- `toggle_selection`, `enter`, `clear_picks` — player actions
- `prepare_entry`, `confirm_onchain_entry` — Phantom onchain entry flow
- `finalize` — Phantom-driven contest creation step 2 (collection route, no `:id`). See `ContestsController#create` + `#finalize`.
- `prepare_onchain_contest`, `confirm_onchain_contest` — legacy Phantom-fund-existing-contest flow; still referenced by `e2e/onchain.spec.js`. Not used by the UI anymore.
- `grade`, `fill`, `lock`, `jump`, `reset` — admin actions
- `grade_round` — survivor admin action: scores the current SurvivorRound + marks picks survived/eliminated
- `payout_entry` — individual entry payout

### Contest Chat (ActionCable)
- `POST /contests/:contest_id/messages` — create chat message (requires `chat_enabled? && chat_participant?(current_user)`)
- `DELETE /contests/:contest_id/messages/:id` — admin soft-delete (sets `hidden_at`)
- Per-contest WebSocket subscription via `turbo_stream_from contest, :messages`. See `docs/UI_PATTERNS.md` § ActionCable.

### Landing Pages
- `/landing/:slug` — public marketing funnel page (hero + contest snapshot + "How it Works")
- `/admin/landing_pages` — admin CRUD (`resources :landing_pages`)

### Account & Auth
- `/account` — profile, password, Google link/unlink. See `docs/AUTH.md`.
- `/auth/solana/nonce`, `/auth/solana/verify` — Phantom wallet auth
- `/wallet` — balance, deposit (quick/Stripe/MoonPay), withdraw, sync
- `/webhooks/stripe`, `/webhooks/moonpay` — payment webhooks (skip CSRF/auth)

### Admin
- `/slates/*` — formula editor. See `docs/FORMULAS.md`.
- `/toast_test` — Toast notification test page (all variants, server-side flash test)
- `/admin/theme` — theme editor (from engine)
- `/admin/jobs` — Sidekiq dashboard (admin-only, mounted via route constraint)
- `/admin/geo` — geo settings
- `/admin/pending_transactions` — Treasury: multisig cosigning queue (Phantom co-sign via JS)
- `/admin/transactions` — transaction log browser
- `/admin/transactions/:slug/complete` — mark approved withdrawal as fiat-sent
- `/error_logs` — error log browser

## Seeds / World Cup Data

- **Shared users**: `db/seeds/users.rb` defines 5 core users (Alex, Alex Bot, Mason, Mack, Turf Monster) with `@mcritchie.studio` emails and real wallet addresses. Loaded by both `db/seeds.rb` and `e2e/seed.rb`.
- 5 seeded users (password: "password"), Alex and Alex Bot are admins
- 48 teams, 72 group stage matches, 85 players
- 9 contests (3 per matchday: small/standard/large), ranks staggered (100-102, 200-202, 300-302), each assigned to admin user (creator)
- Seeds assign ranks idempotently and backfill `user_id` on contests without a creator
- Seed is idempotent (`find_or_create_by!`) — safe to re-run
- All emails use `@mcritchie.studio` domain (seeds, fixtures, E2E tests)
- See `docs/world_cup_2026.md` for format details

## Testing

### Rails Tests
- `bin/rails test` — **198 tests** total (minitest + fixtures)
- Test fixtures: 6 contest_matchups, 6 teams, 2 games
- Test password: `"password"` (min 6 chars)
- Test helper: `log_in_as(user)` defaults to password "password"

### Playwright E2E Tests
- `npm test` — **42 tests** across 8 spec files (chromium project), plus 17 devnet tests
- `npm run test:headed` / `npm run test:ui` — visual modes
- Config: `playwright.config.js` — Chromium only, port 3001
- Seed: `e2e/seed.rb` — 5 users (shared from `db/seeds/users.rb`), 1 contest, 48 matchups
- Helper: `e2e/helpers.js` — `login(page, email, password)`
- **Dev server gotcha**: Local runs hit dev DB, not test seed

## Known Gotchas

- **Theme toggle store**: Engine refactored `Alpine.store('theme')` to an object with `toggle()` method and `isDark` getter. Toggle icons now use Heroicons v2.
- **Hold button guard**: Use `<%== %>` (raw output) in `<script>` tags, NOT `<%= %>` which HTML-escapes `>` to `&gt;`
- **Selection count = 6**: Dynamic via `Contest#picks_required` — all views reference this method
- **Tailwind class compilation**: New utility classes won't compile unless already used elsewhere. Use inline `style` for one-offs.
- **Chart.js + Alpine.js**: Never store Chart.js instances as Alpine reactive properties (Proxy infinite loops). See `docs/FORMULAS.md`.

### Alpine + ERB constraints (critical — silent failures)

Violations of these produce silent no-ops or phantom DOM elements, not errors. Every UI-touching contributor (human + agent) MUST internalize these:

- **`<template x-if>` must have ONE root element.** Multiple siblings silently mount as a no-op. Sibling `<style>` / `<script>` / structural tags are dropped during parsing. Wrap all content in a single outer `<div>`; move styles outside the template.
- **Never combine `@click.outside` with hold buttons.** The button-release click that completes a hold fires AFTER the `@click.outside` listener. A hold that opens a modal via `@click.outside` will have the release click close the freshly-opened modal. Use `@click` instead, or delay the modal open via `setTimeout(500ms)`.
- **`<%# %>` ERB comments terminate at the FIRST `%>` anywhere in the body.** Comment bodies must contain ZERO `%` characters (including CSS `calc()` expressions like `--var: calc(100% - 2rem)` quoted inside a comment). Use HTML `<!-- ... -->` for multi-line notes, or split into multiple `<%# %>` blocks.
- **Never mix `<!--` (HTML) with `%>` (ERB) comment closes.** Mismatched open/close triggers HTML parser recovery and produces phantom DOM elements with mangled attributes (`x-show="null"`) on unrelated siblings. Match the syntax: `<!-- ... -->` for HTML, `<%# ... %>` for ERB.
- **HTML5 forbids `--` inside `<!-- ... -->`** — including CSS custom property refs (`--color-primary`) in dev notes. Parser recovery reparents downstream content into wrong containers (e.g. a board ended up inside a modal card). Use single hyphens or `−`, or move var refs to a `<style>` block / data attributes.
- **`block_given?` inside a partial inherits the layout's `<%= yield %>`** — returns true even when no `do...end` was passed. Calling `yield` then returns the entire enclosing view's HTML. In shared partials, check explicit locals BEFORE `block_given?`: `if locals[:block] || block_given?`.
- **`Alpine.evaluate` is synchronous** — returns `undefined` for async expressions. `evaluateLater`'s `extras` shape is version-dependent. For custom async logic, compile your own `AsyncFunction`: `new Function('return (async () => { ... })')().then(...)`.
- **Cross-component Alpine**: Use global functions/variables instead of `$dispatch`/`$store` for shared state.
- **Navbar / sticky-nav scroll**: Bounce is prevented by `overflow-anchor: none` on `<body>` — shipped by studio-engine (≥0.4.4) from `layouts/studio/_head.html.erb` — which stops Chrome/Firefox scroll-anchoring from dragging `scrollY` when the sticky navbar resizes. The scroll handler is **unthrottled** (throttling drops the trailing event and strands the navbar collapsed); hysteresis is 5/60. Fixed elements below the navbar position off `var(--nav-h)` — a `ResizeObserver`-fed CSS var also shipped by the engine head — never hardcode the offset.

## Workflow

- **Debugging**: STOP and show the issue before fixing
- **Testing**: `bin/rails test` before every commit. Pre-commit hook enforces this.
- **Database**: Migrate and seed freely without asking
- **Server**: Restart proactively after gems/initializers/routes changes
- **Git**: Small frequent commits, push immediately after committing
- **UI**: Style as we build — make it look right the first time

## TODO

- [x] Google OAuth, Solana integration Phases 1-6, remove Ethereum, remove Over/Under, deploy Anchor
- [x] Contest lobby page (`/c/:id/lobby`) — hero banner, inline board/leaderboard, admin section, contest selector
- [x] Stripe/MoonPay deposit actions — `WalletsController#stripe_deposit` + `#moonpay_deposit` are live. Buttons not yet surfaced on `/wallet`; admin 3-step withdrawal flow still pending.
- [x] Entry tokens (web2 contest-entry currency, 2026-05-17/18) — `EntryToken` model + Stripe checkout via `TokensController#stripe_checkout` → `TokenPurchaseJob` (mints tokens, tops up custodial ATA with $19 USDC each, busts `usdc_balance` cache). Post-Stripe redirect lands on `/tokens/processing?session_id=…` which polls `/tokens/status` until tokens are minted, then swaps to a success card. `ContestsController#enter` spends a token before `vault.transfer_from_user` for managed-wallet users. Post-signup upsell redirect in `AccountsController#save_profile`. Webhook controllers skip `:require_authentication` so Stripe POSTs reach the handler. Navbar shows token count when USDC=0 but tokens>0; otherwise dollars. Refund/expiry rules + chargeback handling still TBD.
- [x] **Entry tokens migrated on-chain (2026-05-18)** — `EntryToken` DB model replaced with `EntryTokenAccount` PDA on turf-vault (v0.10.0). DB now has `stripe_purchases` (audit log only: customer_id, session_id, charge_id, mint_tx_signatures, refund_status). Vault gained `mint_entry_token`, `list_entry_tokens`, `enter_contest_with_token`. New Anchor instructions `mint_entry_token` (admin-signed, 1-of-3 vault signer) and `enter_contest_with_token` (consumes token atomically, awards seeds per the Season's seed_schedule, no USDC charged). `ContestsController#enter` checks `user.next_unconsumed_entry_token` and routes to the token path when one exists. Stripe webhook → `TokenPurchaseJob` now calls `Vault.mint_entry_token` once per quantity (source: 'stripe', source_ref: 'stripe:#{session_id}:#{i}'). New admin UI at `/admin/free_entries` shows per-user seeds/level/minted/owed with per-user [Mint N] + [Mint All] buttons (operator-driven; the "Free Entry Earned" badge in the entry modal is a marketing vector, not auto-mint). **KNOWN GAP (intentional for v1):** token-funded entries don't increment `contest.entry_fees` on-chain — operator subsidizes prize pools as needed. See `memory/project_turf_monster_free_entries_onchain.md` for full architecture.
- [x] **Phantom-driven contest creation (2026-05-18)** — `POST /contests` now builds a partially-signed `create_contest` TX (admin pays SOL rent, Phantom signs prize-pool USDC transfer). UI calls `/contests/finalize` after the on-chain TX confirms; only then is the DB row created (`skip_onchain_callback = true`). Click-time prechecks: on-chain Contest PDA must not exist + creator's USDC must cover the prize pool. Insufficient-USDC modal includes a "Mint $500 Test USDC" recovery button that calls `/faucet` and auto-retries. The legacy server-funded path (`Contest#create_onchain!` via `after_create`) is preserved as a fallback for Rails console / scripts and Tests (`Rails.env.test?` auto-skips the callback).
- [x] **Devnet program ID migrated (2026-05-18)** — moved from `7Hy8…r2J` → `Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT`. Original upgrade authority `9Fy8P3…` no longer in our possession; ~3.45 SOL of rent locked at the orphaned program. All on-chain state is fresh on the new program (VaultState `FYBTB5pwoSxN…vpWAn`, Season 1 `C88QKhevowD7…z924`). `SOLANA_PROGRAM_ID` env var holds the new ID; `Solana::Config::PROGRAM_ID` falls back to the old literal — fine for runtime but stale-looking. See `memory/project_turf_program_id_migration_2026_05_18.md`.
- [x] **Stripe payment validator + outbound request audit log (2026-05-19, v73)** — `StripeCheckoutValidator` re-fetches the session via Stripe API after signature verify and asserts payment_status/livemode/kind/amount before mint enqueues (catches metadata tampering, async/unpaid, dev-event-hits-prod). `OutboundRequest` table captures every Stripe + Solana RPC call (Stripe::Instrumentation + prepended Solana::ClientLogger), with sanitized bodies, status, duration, polymorphic source. `Current` attributes flow user + StripePurchase from controllers/jobs into the logger. `TokenPurchaseJob` partial-failure-recoverable (skips already-minted source_refs, persists signatures incrementally). Admin browser at `/admin/outbound_requests`, sweeper trims 90d ok / 180d failed. KNOWN: 6 audit rows per page render from read-only RPCs — add env-gated filter if prod volume gets noisy.
- [x] TurfVault struct reorder — renamed `bonus` → `prizes`, `prize_pool` → `entry_fees`, reordered fields. Deployed to devnet.
- [x] 2-of-3 multisig — TurfVault v0.8.0, Treasury admin page, PendingTransaction model. Deployed to devnet.
- [ ] Update TBD playoff teams once results are in (March 26-31, 2026)
