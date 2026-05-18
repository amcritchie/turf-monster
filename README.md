# Turf Monster

Sports pick'em game for the FIFA World Cup 2026. Players select 5 team matchups with multipliers per entry, scored by actual goals. Features Solana blockchain integration for contest escrow and prize distribution.

**Live**: https://turf.mcritchie.studio

Turf Monster is a **satellite** of [McRitchie Studio](https://github.com/amcritchie/mcritchie-studio) (the SSO hub + flagship of the 5-repo ecosystem).

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

---

## Standing up a fresh Mac? Start at the flagship.

The canonical way to install Turf Monster + all 4 sibling repos + the toolchain is from McRitchie Studio's `bin/ecosystem-build` script. It clones this repo, restores `.env` from Heroku, pulls `SOLANA_ADMIN_KEY` from 1Password, runs `db:create db:migrate db:seed`, and boots the server on port 3001 — all idempotent.

```bash
git clone https://github.com/amcritchie/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/ecosystem-build   # 1st pass: installs toolchain, bails for 1Password token
bin/setup-1pass-token # paste token from clipboard
bin/ecosystem-build   # 2nd pass: completes everything incl. Turf Monster
```

See [mcritchie-studio/docs/agents/system/house-burn-down.md](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for the full protocol.

---

## Single-app dev (when you already have the toolchain)

If your machine already has Ruby 3.1.7 (via `brew install ruby@3.1`), Postgres 14, Redis, Node 20, and an `.env` in place:

```bash
git clone https://github.com/amcritchie/turf-monster.git
cd turf-monster
bundle install
bin/rails db:create db:migrate db:seed
bin/dev
```

`bin/dev` (via Procfile.dev) launches web on port 3001 + Tailwind watcher + Sidekiq. Redis must be running first (`brew services start redis`). Open http://localhost:3001 — login `alex@mcritchie.studio` / `password`.

Seeds create 5 users, 48 World Cup teams, 72 group stage matches, and 67 players.

**Required `.env` keys**: `RAILS_MASTER_KEY` (not optional — seed encrypts managed wallets via `secret_key_base`), `GOOGLE_CLIENT_ID`/`SECRET`, `AWS_ACCESS_KEY_ID`/`SECRET`, `SOLANA_ADMIN_KEY` (1Password `agent.solana`).

## Prerequisites (single-app path)

- Ruby **3.1.7** (use `brew install ruby@3.1` — not mise/rbenv on Apple Silicon, the socket extension silently breaks)
- PostgreSQL 14+
- Redis (Sidekiq queue)
- Node.js **20+** (Node 18 breaks turf-vault's `@solana/codecs-numbers` peer dep)
- Bundler 2.4+

## Test

```bash
# Rails tests
bin/rails test                  # 97 runs, 264 assertions

# Playwright E2E (chromium project — skip @devnet which needs a funded wallet)
npm test                        # 42 tests
npm run test:headed             # with visible browser
```

## Key Features

- **Matchup grid** with team selection, multipliers, and animated hold-to-confirm button
- **Contest lifecycle**: draft, open, locked, settled with admin controls (fill, lock, jump, grade, reset)
- **Multiple entries** per user per contest with different selection combos
- **Scoring**: team goals x multiplier per selection, entries ranked, payouts distributed
- **Solana integration**: on-chain contest escrow via [TurfVault](https://github.com/amcritchie/turf-vault) Anchor program (devnet)
- **Phantom wallet** connect, deposit, withdraw, and direct entry
- **Dark/light theme** toggle with green primary palette

## Deploy

```bash
git push heroku main
heroku run bin/rails db:migrate --app turf-monster
```

Platform: Heroku (heroku-24 stack). Required env vars: `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES=true`, `SOLANA_ADMIN_KEY`, `SOLANA_RPC_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`.

## Solana Integration

The app connects to the TurfVault Anchor program on Solana devnet for contest escrow. Users with Phantom wallets can deposit USDC, enter contests on-chain, and receive payouts. The `SOLANA_ADMIN_KEY` env var holds the admin bot's base58 private key. See `docs/SOLANA.md` for full details.

## Architecture

- Rails 7.2 with ERB views, Tailwind CSS, Alpine.js
- Shared [Studio engine](https://github.com/amcritchie/studio-engine) for auth, error handling, and theme system
- [SolanaStudio](https://github.com/amcritchie/solana-studio) gem for Solana RPC and transaction building
- Slug-based foreign keys for teams, games, and players
- All monetary values stored in cents, displayed in dollars

## Development Notes

See [CLAUDE.md](./CLAUDE.md) for detailed development context including model schemas, route maps, error handling patterns, and code conventions.

Topic-specific documentation lives in `docs/`:

| File | Topic |
|------|-------|
| `docs/AUTH.md` | Authentication, account management, SSO |
| `docs/SOLANA.md` | Solana integration, wallet types, on-chain flows |
| `docs/FORMULAS.md` | Scoring formulas, slate system, Chart.js patterns |
| `docs/UI_PATTERNS.md` | Branding, theme, matchup grid, animations |
| `docs/world_cup_2026.md` | World Cup format, groups, matchday structure |
