# Turf Monster (turf-monster)

Peer-to-peer sports pick'em game focused on team matchup selections with Turf Scores for the World Cup.

## Topic Files

Load these when working on specific areas:

| File | When to read |
|------|-------------|
| `docs/workflows/README.md` | **Workflow index** — user journeys, backend pipelines, operator processes, dev/deploy. Start here when working on any end-to-end flow. |
| `docs/AUTH.md` | Authentication, account management, admin authorization, SSO |
| `docs/SIGNUP_FLOWS.md` | Sign-up flow sequence diagrams (Phantom / Google / manual) |
| `docs/SOLANA.md` | Solana integration, wallet types, onchain flows, rake tasks |
| `docs/FORMULAS.md` | Scoring formulas, slate system, Chart.js patterns |
| `docs/UI_PATTERNS.md` | Branding, theme colors, matchup grid, hold button, animations |
| `docs/world_cup_2026.md` | World Cup format, groups, matchday structure |
| `docs/RATE_LIMITING.md` | Rate limiting — rack-attack throttles, the two-tier general/auth design, wait modals (design spec, pre-build) |

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
pending → open → settled    (locked / concluded are DERIVED, not statuses)
```

- **pending**: Contest created, not yet accepting entries (was `draft` pre-v0.4.1 of audit; Rails 7 reserves `:new` so `pending` was chosen instead)
- **open**: Players can submit entries (toggle selections, hold-to-confirm)
- **settled**: All games scored, entries ranked, payouts distributed
- **locked** (derived, NOT a status column): `Contest#locked?` = `settled? || (starts_at.present? && Time.current >= starts_at)`. Locking is a derived time-gate mirrored from the on-chain `lock_timestamp` — there is no `locked` status. The program rejects entries once chain time passes `lock_timestamp`.
- **concluded** (derived): `Contest#concluded?` derived from `concludes_at` (mirrored from the on-chain `conclusion_timestamp`). `Contest#live?` = `locked? && !settled?`.

### Contest Targeting (root page)

- Root (`/`) redirects to the most recent open/settled contest's **show** page (`/contests/:slug`)
- Falls back to `/contests` index if no eligible contest exists
- `Contest.ranked` scope and `Contest.target` still exist but root no longer uses them
- `load_contest_board_data` — private method used by the `show` action

### Contest Show Page (`/contests/:slug`)

Mobile-first contest page. Renders inline matchup board or leaderboard depending on user state.

**Sections:**
1. Hero banner (Active Storage image or gradient fallback) + creator avatar + Solana PDA overlay (SE corner)
2. Contest info: name, creator, lock time, stats row (prizes, entry fee, entries count, "+ Add Nth Entry" link)
3. Conditional cards: seeds+share (entered users) or info cards (new users)
4. Inline matchup board (not entered) or compact leaderboard (entered)
5. Admin section (Fill / Lock-time / Grade + Simulate buttons) — admin only, unsettled contests
6. Contest selector — other open/settled contests

**Partial `compact` flag**: Both `_turf_totals_board` and `_turf_totals_leaderboard` accept `compact: true` to hide admin buttons, onchain details, and info cards when rendered inline.

`_turf_totals_leaderboard` is **locals-capable** (`local_assigns.fetch(:x, @x)` shim per ivar) so it can render from a model broadcast (`Contest::LiveBroadcast`) where no controller ivars are set, as well as inline from the show action.

### Admin Actions (contest show page + navbar)

- **Fill Contest** — generates random entries (6 random matchups each). Cycles through seeded users. Deduplicates against existing entries.
- **Lock now / Lock in 60s / Conclude in 60s** — set the on-chain `lock_timestamp` / `conclusion_timestamp` (mirrored to `starts_at` / `concludes_at`). **Phantom-signed** (1-of-3; admin's wallet is a vault signer) via `prepare_lock_time`/`confirm_lock_time` + `prepare_conclusion_time`/`confirm_conclusion_time` (ContestsController) + `app/javascript/lock_contest.js`. The show page renders a live lock COUNTDOWN and an "It Begins" modal when it hits zero. There is NO more `lock_contest`/`unlock_contest` (locking is a derived time-gate, not a status transition).
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

- **`bin/tm up`** — the one command to bring the whole local stack up: web (`:3001`) + Sidekiq + the Stripe listener, each **detached** so it survives the terminal and an agent/background session. Companion verbs: `bin/tm down` (stop), `bin/tm restart` (clean bounce — the after-`.env`/gem/migration ritual, since Sidekiq snapshots `.env` at boot), `bin/tm status` (services, ports, one-Sidekiq check, Stripe-secret match), `bin/tm logs [web|sidekiq|stripe]` (tail). It encodes the gotchas in this section so they're never re-derived: preflights redis+postgres, guarantees **exactly one** Sidekiq on `default`+`mailers`, builds Tailwind once (the `--watch` process self-destructs without a TTY), and verifies the Stripe signing secret against `.env`. Idempotent — a second `up` **adopts** the running stack instead of bouncing it. `TM_PORT` / `TM_REDIS_DB` override for an isolated stack (smoke tests / a second checkout).
- **Port 3001** — `bin/rails server -p 3001` (what `bin/tm` runs as `web`).
- `bin/dev` (foreman + `Procfile.dev`) is the interactive **combined-log** alternative for a real terminal. It self-destructs in any background/no-TTY context — the `css` watcher exits without a TTY and foreman then SIGTERMs the rest — so for detached/agent use reach for `bin/tm`. It also does not start the Stripe listener.
- **Redis required** — `brew services start redis`. Used by:
  - Sidekiq (db 0) — background jobs
  - Rails.cache (db 1, namespace `tm-cache`) — `:redis_cache_store` is the dev backend so Sidekiq + Rails server share the same cache (required for `User#bust_entry_tokens_cache!` to propagate across processes; `:memory_store` is per-process and breaks the post-mint refresh).
  - `rack-attack` throttle counters — flooding `/login` during E2E runs trips the throttle and locks tests out. Clear with: `redis-cli --scan --pattern 'rack-attack:*' | xargs redis-cli del`.
- **Stripe listener** — token-purchase + USDC-deposit flows depend on webhook delivery. Without it, `/tokens/processing` polling never resolves. Run in a separate terminal: `stripe listen --forward-to localhost:3001/webhooks/stripe --api-key $STRIPE_SECRET_KEY`. The session-printed `whsec_…` must match `STRIPE_WEBHOOK_SECRET` in `.env`.
- **Solana RPC** — set `SOLANA_RPC_URL` to a Helius endpoint (`https://devnet.helius-rpc.com/?api-key=…`). Public devnet RPC rate-limits `getProgramAccounts` (the call behind `User#entry_token_balance`) to ~1/sec/IP and produces silent UI bugs ("$0 / Buy Tokens" even when the user has tokens). Helius URLs are in 1Password at `agent.helius`.

### Parallel work — worktrees (Claude drives this)

We run several Claude sessions at once. To keep branches from tangling: **the primary checkout (`~/projects/turf-monster`) stays on `main` and is never committed to** — every task, solo or parallel, lives in its own `git worktree` off current `origin/main`. Parallel work is then just more worktrees, which makes a stale/already-merged-branch ("zombie") tangle structurally impossible.

**Branch hygiene — verify before the first edit/commit of ANY task:**
- If you're in the primary checkout, on `main`, or on a branch whose commits are already on `origin/main` (a merged "zombie"), do NOT commit here — start fresh.
- `bin/worktree new <slug>` creates `../turf-monster-<slug>` on `feat/<slug>` off `origin/main` (and copies `.env`). Work there; for a parallel task the operator runs `cd ../turf-monster-<slug> && claude` so that session owns it.
- Ship: small commits → push → `gh pr create` → after merge, `bin/worktree done <slug>` (removes the worktree + branch). **Never reuse a branch after its PR merges.**
- Guardrail: about to commit on anything that isn't a fresh branch off *current* `main`? STOP and flag it — cherry-picking onto a clean branch at ship time is recovery, not the plan.

**Port `:3001` is the canonical/main dev server — reserve it for the primary.** External callbacks are wired to it: the Stripe webhook forward (`localhost:3001/webhooks/stripe`), the Google OAuth redirect URIs, and the dev mailer host (`development.rb` `default_url_options` falls back to `3001`). Worktree stacks run on **3002+** and are fine for general UI/backend dev, but any flow with an external callback — **Stripe, Google OAuth, MoonPay, webhooks, emailed magic-links** — must be exercised on the primary `:3001`.

**Running a worktree's live dev stack:** `bin/parallel-server [PORT] [REDIS_DB]` (defaults `3002` / Redis db `9`) from the primary worktree — it creates a sibling worktree off `origin/main`, copies `.env`, builds Tailwind, and starts web + Sidekiq isolated. Ctrl-C stops both; clean up with `git worktree remove <path> --force && git worktree prune`. Rule of thumb: use `bin/worktree` when you need a *named feature branch to commit on*; use `bin/parallel-server` when you just need a second *running* stack.

Why the isolation matters (each of these silently collides otherwise):
- **Port + mailer links** — the dev mailer host port reads `APP_PORT` (default 3001) in `config/environments/development.rb`, so emailed links (e.g. magic links) point at *this* server instead of `:3001`.
- **Redis** — Sidekiq + `Rails.cache` both read `REDIS_URL` (defaults db 0 / db 1). The script points both at `redis://localhost:6379/<REDIS_DB>` so a second stack doesn't process the other's jobs or share its cache.
- **Secrets** — a fresh worktree has no `.env` (there is no `config/master.key`; secrets live in `.env` via `RAILS_MASTER_KEY`/`SECRET_KEY_BASE`/`MANAGED_WALLET_ENCRYPTION_KEY`). The script copies it from the primary.
- **Test DB** — for the suite, use a separate DB so you don't fight the shared schema: `DATABASE_URL=postgresql:///turf_monster_test_auth RAILS_ENV=test bin/rails db:create db:schema:load test`. Test cache is `:null_store`, so anything keyed on `Rails.cache` (single-use jti, etc.) must be asserted with an injected `MemoryStore` in a service test, not via the controller.

## Deployment

- **Heroku app**: `turf-monster`
- **URL**: https://turf.mcritchie.studio
- **Database**: Heroku Postgres (essential-0)
- **Redis**: Heroku Redis mini (`redis-clear-09691`) — `REDIS_URL` set automatically
- **Deploy**: `bin/deploy` — wraps `git push heroku main` + auto-migrates + pre-flight checks (IDL hash drift, `SKIP_IDL_VERIFICATION` set, Stripe test-mode key, dirty tree, failing tests). `bin/deploy --help` for options. **One-time mainnet first deploy**: follow `MAINNET_LAUNCH.md` instead.
- **Pre-flight health check** — before any cluster flip (devnet ↔ mainnet) or new Heroku app activation, run `bin/rails solana:health` (locally or via `heroku run`). Validates that NETWORK + RPC_URL + PROGRAM_ID + EXPECTED_IDL_HASH all agree: genesis-hash match, program-exists-on-RPC, IDL-hash-match. Exits non-zero on mismatch — wire into release scripts that need a green Solana stack before serving traffic. The boot-time `solana_network_alignment.rb` initializer (OPSEC-039) catches the same drift but only at process start; the rake is the version you run before flipping.
- **Mainnet RPC** — Helius mainnet URL in 1Password at `agent.helius` alongside the devnet URL. Each Heroku app sets `SOLANA_RPC_URL` to the URL for its own cluster (the app doesn't pick by cluster — one URL per app). Mainnet config-vault set: `heroku config:set SOLANA_NETWORK=mainnet-beta SOLANA_RPC_URL=$(op read 'op://Agent/helius/mainnet') -a turf-monster-mainnet`.
- **Env vars** (currently set on Heroku): `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, `DATABASE_URL` (auto), `REDIS_URL` (auto), `RAILS_SERVE_STATIC_FILES`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `RESEND_API_KEY`, `MAILER_FROM`, `MANAGED_WALLET_ENCRYPTION_KEY`, `EXPECTED_IDL_HASH`, `SOLANA_PROGRAM_ID`. See `.env.example` for the full documented set (including `SOLANA_ADMIN_KEY` / `SOLANA_RPC_URL` for local dev).

## Tech Stack

- Ruby 3.1 / Rails 7.2 / PostgreSQL 14
- Tailwind CSS via `tailwindcss-rails` gem (compiled, not CDN)
- Alpine.js via CDN for interactivity
- ERB views, import maps, no JS frameworks
- bcrypt + Google OAuth + Solana wallet auth (Phantom)
- **Sidekiq** + Redis for background jobs (web UI at `/admin/jobs`, admin-only)
- **Studio engine gem** — `gem "studio-engine", "~> 0.4.0"` (RubyGems; current 0.4.10). `Studio.routes(self)` + `Studio.configure` in `config/initializers/studio.rb`.
- **SolanaStudio gem** — `gem "solana-studio", "~> 0.4.3"` (RubyGems; current 0.4.3). Pure-Ruby primitives — Solana::Client (RPC), Solana::Borsh, Solana::Transaction, Solana::SplToken, Solana::Keypair. 0.4.3 fixes the `Net::HTTP::Post.new(@uri.path)` query-string-dropping bug that broke Helius auth in 0.4.2 (see solana-studio PR #1 + CHANGELOG).

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
- `state_fanout` — `window.StateFanout.apply(stateType, payload, opts)`. See "State fanout pattern" below for the contract. Registered handlers: `seeds`. Add a new handler when the next on-chain state delta needs to fan out to localStorage + a navbar event.

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

### State fanout pattern

When the server confirms an on-chain state change, three things have to happen on the client to keep the UI consistent:

1. **localStorage write** — the navbar (seeds bar, token badge, etc.) reads its initial value from localStorage on the next render. Forgetting this leaves the bar stuck at a stale value until the 60s `Rails.cache` TTL expires.
2. **Window event dispatch** — long-lived Alpine components animate to the new value without a page reload. The seeds bar listens on `navbar-seeds-update`, etc.
3. **Structured console log** — `[state-fanout][<key>] { source, ... }` so LogRocket session replays + Sentry breadcrumbs can triage staleness in prod. Pair this with the server-side log (e.g. `[entry][confirmed]`) — same `tx_signature` correlates the two sides.

`window.StateFanout.apply(stateType, payload, opts)` (defined in `app/javascript/state_fanout.js`) handles all three for any registered state type. Each handler owns the localStorage key shape, the event name + detail, and what counts as a no-op (`seeds` skips when `seeds_earned` is 0).

**Handler contract** — to add a new on-chain state type, register a handler in `state_fanout.js`:

```js
register("tokens", function (payload, source, opts) {
  // 1. Validate payload + extract canonical value
  // 2. Write the localStorage key the navbar/badge reads
  // 3. setTimeout(() => window.dispatchEvent(new CustomEvent("navbar-tokens-update", { detail })), opts.dispatchDelay || 2000)
  // 4. console.log("[state-fanout][tokens]", { source, ... })
});
```

The `source` param identifies which code path called `apply()` (e.g. `phantom-direct` vs `managed-wallet` for the seeds handler). It appears in every log line so a stuck navbar in prod can be triaged to a specific entry-flow path.

**Currently registered:**

| stateType | server endpoints | localStorage keys | event |
|---|---|---|---|
| `seeds` | `/contests/:id/enter`, `/confirm_onchain_entry` | `seedsNavbar`, `seedsLevelUp` (on level-up) | `navbar-seeds-update` |

### CSS Grid card layout — drop inner `mb-*`

A card that sits in a CSS Grid row (`grid-cols-2` etc.) with `align-items: stretch` (the default) will be stretched to match its row-neighbour's height — but if it carries its own `mb-*` class, that margin reduces the visible box size INSIDE the grid cell. You get the cell at the right height with the visible card 16-24px shorter, breaking parity with the neighbour.

**Rule:** cards rendered directly as grid children must NOT carry `mb-*` on themselves. The parent of the grid is the right place for any bottom spacing.

Burned by this three times so far:

- `_share_invite.html.erb` (was `card shadow p-5 mb-6`)
- `_slate_progress_xp.html.erb` (was `card shadow p-5 mb-6`)
- `_your_entries.html.erb` (never had it; built clean from the start)

If a card needs `mb-*` outside grid contexts, wrap it in a `<div class="mb-6">` at the *call site* rather than baking it into the partial.

### Named Tailwind breakpoints (semantic > pixel)

The `min-[Npx]:` arbitrary syntax works but reads as a magic number. When a breakpoint captures a *layout* decision (a specific component's column width gating which content fits), promote it to a named entry in `tailwind.config.js → theme.extend.screens`:

```js
screens: {
  'pill-narrow': '530px',  // smallest Your Entries pill cell that fits emoji+short_name
}
```

Then the markup reads `pill-narrow:inline` instead of `min-[530px]:inline` — and the next caller wanting the same boundary (other compact pill grids, etc.) has a discoverable name to reach for. Don't name a breakpoint after a device (`tablet`, `phone`) — that's what `sm`/`md`/`lg` are for; name it after the layout constraint it represents.

## Studio Engine

Shared code from [studio engine](https://github.com/amcritchie/studio-engine). Configured in `config/initializers/studio.rb`.

**From the engine:** `Studio::ErrorHandling`, `ErrorLog` model, `Sluggable` concern, auth controllers, error log views, theme system, `_theme_toggle_morph` partial (spinner/toggle swap), `showNavSpinner`/`hideNavSpinner` globals, **`Studio::S3`** + **`Studio::ImageCache`** + `ImageCache` model.

**Overridden locally:** `sessions/new.html.erb`, `sessions_controller.rb` (SSO removed — 404s `sso_continue`/`sso_login`, see audit C3 + `docs/AUTH.md`), `registrations/new.html.erb`, `omniauth_callbacks_controller.rb` (merge support), `layouts/_navbar.html.erb` (app-specific nav links, mobile sub-navbar with duplicate gear+moon fix).

**Routes:** `Studio.routes(self)` draws `/login`, `/signup`, `/logout`, `/sso_continue`, `/sso_login`, `/auth/:provider/callback`, `/error_logs`, `/admin/theme`. `/sso_continue` and `/sso_login` return 404 — the local `SessionsController` overrides them. Cookie key is `_turf_session` (not the hub's `_studio_session`) and no longer scoped to `.mcritchie.studio` — the hub session is invisible here.

**S3 config:** `config.s3_bucket_prefix = "turf-monster"` overrides the engine default — bucket resolves to `turf-monster-dev` (dev/test) or `turf-monster-production` (prod). All 4 studio buckets are public-read; `mcritchie-studio-dev` has a 90-day GLACIER_IR archive rule. AWS creds via shared `op://` refs in `/Users/alex/projects/.env` (Heroku needs `heroku config:set AWS_*` separately — not yet done). `image_caches` table created 2026-04-29; not yet used by any model in this app.

**Updating:** After changes to the studio repo, run `bundle update studio-engine` here.

## Architecture

- Money stored in cents, displayed in dollars via `dollars()` helper
- **6 selections per entry** — `Contest#picks_required` returns 6. All views use this dynamically. Max 3 entries per user per contest (`Contest#max_entries_per_user`).
- **Balance system (v0.16)**: USDC lives in each user's own ATA — no custodial vault balance. Web2/managed-wallet users have their keypair server-held (`encrypted_web2_solana_private_key`), but the USDC destination is still their ATA. `display_balance` reads the ATA directly via Helius RPC; `User#entry_token_balance` reads on-chain `EntryTokenAccount` PDAs. Both reads cached 60s in Redis (`User#cached_entry_tokens` + `usdc_cache_key`); callers that mint/consume tokens MUST follow up with `user.bust_entry_tokens_cache!` to propagate to the navbar + eligibility blocker in the same request cycle.
- **Token purchases ($19 / 3-for-$49)** mint on-chain `EntryTokenAccount` PDAs via `TokenPurchaseJob`. **No USDC top-up** — the token IS the value; redemption goes through `enter_contest_with_token` which skips the USDC transfer. (Pre-v0.10 the flow ALSO topped up $19 of USDC per token; that was dropped when tokens moved on-chain.)
- **Slug-based foreign keys**: Teams, Games, Players use slug columns as FKs (e.g. `team_slug`, `home_team_slug`). Associations use `foreign_key: :*_slug, primary_key: :slug`.
- **Turf Score formula**: `1.0 + 2.0 * ln(rank) / ln(N)` — x1.0 at rank 1 to x3.0 at rank N. Centralized on `SlateMatchup.turf_score_for(rank, n)` (scale `2.0` = `Slate::FORMULA_DEFAULTS[:formula_mult_scale]`, per-slate overridable; JS mirrors in `slates/show.html.erb` + `formula_report.html.erb`).
- **Seeds system**: seeds awarded on-chain per the active Season's `seed_schedule` (default `[25, 19, 14, 10, 7]` — entry 0→25, clamping to slot 4); no DB column for the count. See `docs/SOLANA.md`.
- **Entry tokens**: on-chain `EntryTokenAccount` PDAs (turf-vault v0.9.0+). DB `stripe_purchases` is audit-only. See `Solana::Vault#list_entry_tokens` and `app/controllers/admin/free_entries_controller.rb`.
- Entry slug includes `id` — requires `after_create` callback
- Every page shows JSON debug block of its primary record

## Models

- **User** — name, username, email (nullable), solana_address, wallet_type, role, slug. Balance is on-chain USDC. See `docs/AUTH.md`.
- **Contest** — name, tagline, entry_fee_cents, status (`pending`/`open`/`settled` — no `locked`), max_entries, rank, season_id (OPSEC-023), slate association, onchain fields, slug. On-chain `lock_timestamp`/`conclusion_timestamp` mirrored to the `starts_at`/`concludes_at` columns. `belongs_to :user` (creator, optional). `has_one_attached :contest_image` (Active Storage). Helpers: `lock_time_display`, `active_entry_count`, `locks_at` (alias for `starts_at`), `locked?`, `concluded?`, `live?`, `games_by_phase`. Contest's matchups come from `SlateMatchup` via the associated `Slate` — there is no separate `ContestMatchup` model.
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

- ContestsController: toggle_selection, enter, clear_picks → `target: entry, parent: @contest`. Grade, fill, jump, reset, update, prepare/confirm_lock_time, prepare/confirm_conclusion_time → `target: @contest`.
- AccountsController: update, unlink_google, change_password → `target: current_user`

## Routes

### Public
- `/` — contests#world_cup (redirects to most recent contest's show page)
- `/contests` — contests#index (card grid, newest first, banner images, "My Contests" + "New Contest" buttons)
- `/contests/:id` — contest show (mobile-first contest page — hero, inline board/leaderboard, admin section, contest selector). "Watch Live" button surfaces when `live?`.
- `/contests/:id/live` — contests#live → `contests/live.html.erb`. Live active-contest page: real-time leaderboard + chat + a single auto-rotating games row, pushed over ActionCable via `Contest::LiveBroadcast` (broadcasts on Goal create/destroy + `Admin::GamesController#complete_game`). Toast fires from a hidden goal-feed + MutationObserver (Turbo doesn't run scripts in broadcast templates).
- `/contests/:id/edit` — admin contest editor (name, tagline, status, rank, image, locks_at)
- `/teams`, `/teams/:slug` — team index/show
- `/games` — games index
- `/faucet` — public faucet page (GET marketing, POST mint USDC)
- `/geo/check` — geo detection JSON (no auth)

### Contest Actions (POST)
- `toggle_selection`, `enter`, `clear_picks` — player actions
- `prepare_entry`, `confirm_onchain_entry` — Phantom onchain entry flow
- `prepare_lock_time`, `confirm_lock_time`, `prepare_conclusion_time`, `confirm_conclusion_time` — Phantom-signed (1-of-3) set of the on-chain `lock_timestamp` / `conclusion_timestamp`. Replaces the old `lock_contest`/`unlock_contest`. See `app/javascript/lock_contest.js`.
- `finalize` — Phantom-driven contest creation step 2 (collection route, no `:id`). See `ContestsController#create` + `#finalize`.
- `prepare_onchain_contest`, `confirm_onchain_contest` — legacy Phantom-fund-existing-contest flow; still referenced by `e2e/onchain.spec.js`. Not used by the UI anymore.
- `grade`, `fill`, `jump`, `reset` — admin actions (no more `lock`; locking is the Phantom-signed `*_lock_time` flow above)
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
- `npm test` — **72 tests** across 9 spec files (chromium project), plus 17 devnet tests
- `npm run test:headed` / `npm run test:ui` — visual modes
- Config: `playwright.config.js` — Chromium only, port 3001
- Seed: `e2e/seed.rb` — 5 users (shared from `db/seeds/users.rb`), 2 contests (turf-totals + survivor), 48 matchups, 1 faucet TransactionLog. Run with `bin/rails runner e2e/seed.rb` (against the dev server's DB by default).
- Helper: `e2e/helpers.js` — `login(page, email, password)`
- **`/test/*` routes** (`test/oauth_mock`, `test/set_user_referral_counts`, `test/create_active_entry`, `test/user_info/:slug`) — gated `unless Rails.env.production?` so Playwright (which runs against the dev server) can reach them. Implemented by `TestController`; never reachable in prod.
- **OmniAuth mocks** — `OmniAuth.config.test_mode = true` is set in `development.rb` after_initialize (gated to dev only) so the `referrals.spec.js` Google-OAuth path uses the mock_auth hash POSTed by Playwright instead of redirecting to Google.
- **Test contests are off-chain** — `e2e/seed.rb` creates the test contests with `skip_onchain_callback = true`. On-chain entry coverage lives in `e2e/devnet-smoke.spec.js`, which sets up its own fresh on-chain Contest PDAs.
- **User sequence reset** — seed runs `ALTER SEQUENCE users_id_seq RESTART WITH 1` so seeded users land at IDs 1..5. `referrals.spec.js` hardcodes inviter slugs (`mason-3`, `mack-4`, `turf-5`) that depend on this.
- **`rack-attack` throttle pollution between runs** — heavy login traffic accumulates throttle counters in Redis. If `loginAdmin` starts timing out across many specs, clear with: `redis-cli --scan --pattern 'rack-attack:*' | xargs redis-cli del`. Worth wrapping in a `globalSetup` in `playwright.config.js` (tracked TODO).
- **State pollution across spec files** — the dev DB accumulates entries / TransactionLogs / GeoSettings across the full suite. Same tests pass in isolation but fail in full-suite runs. Re-running `e2e/seed.rb` between spec files would isolate them (tracked TODO).

## Known Gotchas

- **Helius RPC required, not optional**: any deployment (dev included, mainnet definitely) MUST set `SOLANA_RPC_URL` to a private endpoint. Public `api.devnet.solana.com` rate-limits `getProgramAccounts` aggressively → `entry_token_balance` rescues to 0 → navbar shows "$0 / Buy Tokens" even when the user has tokens. See the Solana RPC bullet under Dev Server.
- **`bust_entry_tokens_cache!` is required after on-chain mint/consume**: `Solana::Vault.list_entry_tokens` is cached for 60s in Redis. `TokenPurchaseJob` and `enter_contest_with_token` consumers MUST call `user.bust_entry_tokens_cache!` once the chain TX confirms, or `$store.session.tokensAvailable` (and therefore `eligibilityBlocker`) sees stale 0 right after a successful purchase.
- **`/tokens/status` busts the cache before reading** — Helius's index can lag a few hundred ms behind a confirmed mint TX. If a polling fetch lands in that window with a stale cache, the empty array gets cached for 60s and the modal renders "0 available". The polling endpoint forces a fresh fetch on every poll.
- **Post-mint UI fanout — three things to update, not one**: `updateNavTokens(balance)` updates the navbar DOM. `Alpine.store('session').tokensAvailable = balance` is what `eligibilityBlocker` reads at hold-time. `bust_entry_tokens_cache!` is what subsequent server-side balance reads need. ALL THREE must happen post-mint or the next user action sees stale state.
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
- [x] Contest show page (`/contests/:slug`) — hero banner, inline board/leaderboard, admin section, contest selector
- [x] Stripe/MoonPay deposit actions — `WalletsController#stripe_deposit` + `#moonpay_deposit` are live. Buttons not yet surfaced on `/wallet`; admin 3-step withdrawal flow still pending.
- [x] Entry tokens (web2 contest-entry currency, 2026-05-17/18) — `EntryToken` model + Stripe checkout via `TokensController#stripe_checkout` → `TokenPurchaseJob` (mints tokens, tops up custodial ATA with $19 USDC each, busts `usdc_balance` cache). Post-Stripe redirect lands on `/tokens/processing?session_id=…` which polls `/tokens/status` until tokens are minted, then swaps to a success card. `ContestsController#enter` spends a token before `vault.transfer_from_user` for managed-wallet users. Post-signup upsell redirect in `AccountsController#save_profile`. Webhook controllers skip `:require_authentication` so Stripe POSTs reach the handler. Navbar shows token count when USDC=0 but tokens>0; otherwise dollars. Refund/expiry rules + chargeback handling still TBD.
- [x] **Entry tokens migrated on-chain (2026-05-18)** — `EntryToken` DB model replaced with `EntryTokenAccount` PDA on turf-vault (v0.10.0). DB now has `stripe_purchases` (audit log only: customer_id, session_id, charge_id, mint_tx_signatures, refund_status). Vault gained `mint_entry_token`, `list_entry_tokens`, `enter_contest_with_token`. New Anchor instructions `mint_entry_token` (admin-signed, 1-of-3 vault signer) and `enter_contest_with_token` (consumes token atomically, awards seeds per the Season's seed_schedule, no USDC charged). `ContestsController#enter` checks `user.next_unconsumed_entry_token` and routes to the token path when one exists. Stripe webhook → `TokenPurchaseJob` now calls `Vault.mint_entry_token` once per quantity (source: 'stripe', source_ref: 'stripe:#{session_id}:#{i}'). New admin UI at `/admin/free_entries` shows per-user seeds/level/minted/owed with per-user [Mint N] + [Mint All] buttons (operator-driven; the "Free Entry Earned" badge in the entry modal is a marketing vector, not auto-mint). **KNOWN GAP (intentional for v1):** token-funded entries don't increment `contest.entry_fees` on-chain — operator subsidizes prize pools as needed. See `memory/project_turf_monster_free_entries_onchain.md` for full architecture.
- [x] **Phantom-driven contest creation (2026-05-18)** — `POST /contests` now builds a partially-signed `create_contest` TX (admin pays SOL rent, Phantom signs prize-pool USDC transfer). UI calls `/contests/finalize` after the on-chain TX confirms; only then is the DB row created (`skip_onchain_callback = true`). Click-time prechecks: on-chain Contest PDA must not exist + creator's USDC must cover the prize pool. Insufficient-USDC modal includes a "Mint $500 Test USDC" recovery button that calls `/faucet` and auto-retries. The legacy server-funded path (`Contest#create_onchain!` via `after_create`) is preserved as a fallback for Rails console / scripts and Tests (`Rails.env.test?` auto-skips the callback).
- [x] **Devnet program ID migrated (2026-05-18)** — moved from `7Hy8…r2J` → `Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT`. Original upgrade authority `9Fy8P3…` no longer in our possession; ~3.45 SOL of rent locked at the orphaned program. All on-chain state was fresh on that program at the time. **Superseded 2026-05-31:** the devnet program later migrated again to `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ` (v0.18); `SOLANA_PROGRAM_ID` holds it and the `Solana::Config::PROGRAM_ID` fallback now matches (no longer the old literal). Current devnet PDAs: VaultState `J7b5g9uS5M2Nog1Ly1UATXTDMtXdpXK3JffRAHXGHkK2`, Season 1 `7dqPQaPrM1uixt5cVTVphwc3eK5o8wkndASyXwooFpFb`. See `docs/SOLANA.md` and `memory/project_turf_program_id_migration_2026_05_18.md`.
- [x] **Stripe payment validator + outbound request audit log (2026-05-19, v73)** — `StripeCheckoutValidator` re-fetches the session via Stripe API after signature verify and asserts payment_status/livemode/kind/amount before mint enqueues (catches metadata tampering, async/unpaid, dev-event-hits-prod). `OutboundRequest` table captures every Stripe + Solana RPC call (Stripe::Instrumentation + prepended Solana::ClientLogger), with sanitized bodies, status, duration, polymorphic source. `Current` attributes flow user + StripePurchase from controllers/jobs into the logger. `TokenPurchaseJob` partial-failure-recoverable (skips already-minted source_refs, persists signatures incrementally). Admin browser at `/admin/outbound_requests`, sweeper trims 90d ok / 180d failed. KNOWN: 6 audit rows per page render from read-only RPCs — add env-gated filter if prod volume gets noisy.
- [x] TurfVault struct reorder — renamed `bonus` → `prizes`, `prize_pool` → `entry_fees`, reordered fields. Deployed to devnet.
- [x] 2-of-3 multisig — TurfVault v0.8.0, Treasury admin page, PendingTransaction model. Deployed to devnet.
- [ ] Update TBD playoff teams once results are in (March 26-31, 2026)
