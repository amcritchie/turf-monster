# Solana Integration (Devnet)

"DeFi mullet" — Web2 UX front, Solana settlement back. Onchain methods are non-blocking (rescue + log errors) so app works without deployed program.

## Services (`app/services/solana/`)

- `Solana::Config` — program ID, RPC URL, mints, network
- `Solana::Client` — JSON-RPC HTTP wrapper (Net::HTTP), retry logic
- `Solana::Keypair` — Ed25519 key gen, encrypt/decrypt via Rails master key, sign, base58
- `Solana::Borsh` — minimal Borsh serialization
- `Solana::Transaction` — transaction builder, Anchor discriminators, PDA derivation
- `Solana::Vault` — high-level business logic (deposit, withdraw, enter, settle, sync). `sync_balance` decodes seeds from UserAccount PDA. `build_enter_contest_direct` includes `user_account` PDA for seeds award.
- `Solana::Reconciler` — compare DB vs onchain balances, log discrepancies. Runs every 15 minutes via `Solana::ReconcileJob` (sidekiq-cron, schedule in `config/schedule.yml`). Discrepancies are written to `ErrorLog` and (when `RECONCILER_ALERT_WEBHOOK` env var is set to a Slack/Discord incoming webhook URL) posted there. See [secrets-rotation runbook](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/secrets-rotation.md) for webhook setup steps.

## Anchor Program (`turf-vault/`)

Separate project at `/Users/alex/projects/turf-vault/`. PDAs: VaultState, UserAccount, Contest, ContestEntry. Instructions: initialize, create_user_account, deposit, withdraw, create_contest, enter_contest, settle_contest, close_contest, force_close_vault, update_signers.

**Deployment status**: v0.8.0 deployed to devnet. 2-of-3 multisig for treasury ops.
- Program ID: `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J`
- Vault PDA: `7z313HTVNcxhvCBkkDQv794RpXeRrfCLb5WJ4dFAQQeh`
- Signer 1 (server): Alex Bot — `F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ`
- Signer 2: Alex — `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
- Signer 3: Mason — `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`
- Threshold: 2-of-3 (treasury ops only)
- IDL Account: `DCP2XRu8ZwzsCpXBgu5xa4vTYdYQhKUZRU49iJuFv8Lf`
- USDC Mint: `222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9`
- USDT Mint: `9mxkN8KaVA8FFgDE2LEsn2UbYLPG8Xg9bf4V9MYYi8Ne`

### Multisig Settlement Flow
1. `Contest#grade!` scores entries and calls `settle_onchain!`
2. `settle_onchain!` calls `Vault#build_settle_contest` → creates `PendingTransaction` with partially-signed TX
3. Admin visits `/admin/pending_transactions` (Treasury page)
4. Clicks "Co-sign" → Phantom signs as cosigner → TX submitted to Solana
5. Server records signature, marks contest `onchain_settled: true`

## Navbar Balance

`display_balance` helper shows the user's on-chain USDC balance (cached 60s) for all wallet types. Falls back to 0 on error. The `/admin/usdc_balance` JSON endpoint (used by `refreshBalance()` JS) follows the same logic. Both use `fetch_user_usdc` → `Vault#fetch_wallet_balances(current_user.solana_address)`.

**Balance refresh system**: `refreshBalance()` fetches `/admin/usdc_balance` and updates all `[data-balance-display]` elements. `refreshBalanceDelayed(ms)` waits (default 10s) then calls `refreshBalance()` — spins the navbar refresh icon (`[data-balance-refresh]`) during the wait as a visual cue. Called automatically after Solana operations (faucet, contest creation, payout). Manual refresh button (circular arrows icon) next to the balance in navbar (desktop + mobile).

## Wallet Types

- **Managed**: Server generates + encrypts Ed25519 keypair, signs transactions on behalf of user (formerly "custodial")
- **Phantom**: User connects Phantom browser extension, signs transactions directly

## Hard Escrow Contest Creation (v0.4.0)

Contest creation transfers prizes USDC from creator's Phantom wallet to vault — real hard escrow, not just a number on the PDA. Dual-signer: admin bot pays SOL rent, creator's Phantom signs the USDC transfer.

1. Admin fills form + submits → `POST /contests` (creates DB record)
2. `POST /contests/:id/prepare_onchain_contest` → server builds + admin partial-signs tx
3. `phantom.signTransaction(tx)` → creator co-signs the prizes USDC transfer
4. `connection.sendRawTransaction()` → submit to Solana
5. `POST /contests/:id/confirm_onchain_contest` → saves onchain_contest_id + tx_signature

Replaced the old server-only `create_onchain` flow. Contest model's `create_onchain!` method removed. Vault service uses `build_create_contest` (partial-sign) instead of `create_contest` (full-sign).

## Dual-Path Onchain Entry Flow

Two paths for entering onchain contests, determined by wallet type:

**Phantom (direct path)**: User's USDC transfers directly from their wallet ATA to vault via `enter_contest_direct` Anchor instruction. Admin pays PDA rent, user signs token transfer. Flow:
1. Hold completes → sign identity message → `POST /prepare_entry` (server builds + partial-signs tx)
2. `phantom.signTransaction(tx)` → user co-signs the USDC transfer
3. `connection.sendRawTransaction()` → submit to Solana
4. `POST /confirm_onchain_entry` → confirm in DB (no DB balance deduction)

**Managed / non-onchain (standard path)**: Server deducts DB balance, admin-signs `enter_contest` (existing PDA balance deduction). Unchanged from before.

Key difference: Phantom users' navbar shows wallet USDC (fetched live), which decreases naturally after the onchain transfer — no DB balance tracking needed.

## Seeds System (On-Chain)

Seeds are awarded on-chain per the active **Season**'s `seed_schedule` (TurfVault v0.11.0+). Default schedule is `[25, 19, 14, 10, 7]` — entry index 0 → 25 seeds, index 4+ clamps to slot 4. No DB columns for the seeds count itself — read from `UserAccount` PDA via `Solana::Vault#sync_balance`. UI-derived levels: `level = seeds / 100 + 1`. Class methods on User: `level_for(seeds)`, `seeds_toward_next_level(seeds)`, `seeds_progress_percent(seeds)`. Constant: `SEEDS_PER_LEVEL = 100`. The active season is tracked in `SeasonConfig.current_season_id` (Rails DB singleton); the on-chain `Season` PDA lives at `[b"season", season_id_le]`. To compute how many seeds an entry will award: `Solana::Vault.new.seeds_for_entry(entry_num)`. Progress bar partial `_seeds_bar.html.erb` (used in both navbar via `_user_nav` and contest show via `_slate_progress_xp`). Level-up animation with confetti on progress bar; "Free Entry Earned 🎟️" badge in the entry-confirm modal (cosmetic — operator mints actual EntryTokenAccount PDAs via `/admin/free_entries`). `User#level` column (integer, default 1) persisted via `update_level_from_seeds!` endpoint (`PATCH /account/update_level`).

## Rake Tasks

- `solana:init_vault` — initialize vault on Devnet (`INIT=true ADMIN_BACKUP=<base58>`)
- `solana:airdrop` — airdrop SOL to admin
- `solana:check_balance` — read onchain balance
- `solana:faucet` — mint test USDC
- `solana:reconcile` — reconcile all user balances
- `solana:reconcile_contest` — reconcile specific contest

## Solana Auth Security

- **Nonce replay prevention**: Solana nonces include timestamp, enforced 5-minute expiry window. Nonce is deleted from session before verification (delete-before-verify pattern) to prevent replay attacks.
