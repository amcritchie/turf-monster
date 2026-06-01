# Solana Integration (Devnet)

"DeFi mullet" — Web2 UX front, Solana settlement back. **Read paths** rescue-and-log (balance/seeds display falls back to 0 on RPC error). **Money-mutating paths** (create_contest, enter, settle) are TX-first — the on-chain transaction confirms *before* the DB row is written/promoted — and fail closed: `Solana::Vault.ensure_program_id_live!` raises if `PROGRAM_ID` isn't on the RPC, and `Solana::Config.verify_idl!` refuses to boot/precompile in prod on IDL drift. The app does not transact against a missing or IDL-mismatched program.

## Architecture: self-custody (v0.16+)

There is **no custodial vault balance**. USDC and USDT live in each user's **own ATA**:
- **Managed (web2) wallets** — Rails holds the user's Ed25519 secret, encrypted at rest, and server-signs on their behalf. Funds still sit in the user's ATA.
- **Phantom (web3) wallets** — true self-custody; the user signs in the browser.

Money movement is decoupled into two PDA families (both owned/authority = the `VaultState` PDA, neither is a pooled "vault balance"):
- **Entry fees** → per-currency **operator-revenue** ATA `[b"op_rev", mint]`. `enter_contest` SPL-transfers the fee from the user ATA into here.
- **Prize pools** → per-contest **prize-pool** ATA `[b"prize_pool", contest_id]`, pre-funded by the contest creator at `create_contest`. Settlement pays winners out of this.

The two are **decoupled**: entry fees are operator revenue and do **not** count toward the settlement cap. The only settlement constraint is `sum(payouts) <= contest.prize_pool`.

## Services (`app/services/solana/`)

Local (turf-monster) classes:
- `Solana::Config` — program ID, RPC URL, mints, network, signer set, IDL pinning (`verify_idl!`).
- `Solana::Keypair` — Ed25519 keygen, sign, base58, and encrypt/decrypt of managed-wallet secrets via a 256-bit key derived from the **`MANAGED_WALLET_ENCRYPTION_KEY`** env var (OPSEC-015; `secret_key_base[0,32]` is a legacy fallback only). `#inspect`/`#to_s` are redacted (OPSEC-021).
- `Solana::Vault` — high-level builders + senders for every v0.18 instruction (see table below). Each has a server-signed form (managed wallet) and a `build_*` partial-signed form (Phantom co-sign). `sync_balance` surfaces the user's USDC ATA balance (back-compat `:balance` key) + decodes `seeds` from the `UserAccount` PDA; `fetch_wallet_balances` reads USDC/USDT ATAs; `ensure_program_id_live!` guards stale env.
- `Solana::TxVerifier` — fetches a confirmed TX and asserts it touches `PROGRAM_ID` with the expected Anchor discriminator + signer + writable PDA (OPSEC-010). Defeats "submit any successful signature."
- `Solana::ErrorInterpreter` — maps on-chain error codes into the JS eligibility-blocker `{reason, mode, data}` shape.
- `Solana::Reconciler` — compares **on-chain contest state** (entry counts, slot-0 `entry_fees`) and per-user on-chain account presence against the DB; writes discrepancies to `ErrorLog` only. **No** Slack/Discord webhook. The scheduled cron was **removed 2026-05-19 (OPSEC-040)** — run ad-hoc via the rake tasks below.
- `Solana::ClientLogger` — prepended onto the RPC client to write `OutboundRequest` audit rows.

RPC + serialization primitives come from the **`solana-studio` gem** (`~> 0.4.3`), not local: `Solana::Client` (JSON-RPC over Net::HTTP, retry/blockhash logic), `Solana::Borsh`, `Solana::Transaction` (builder, `find_pda`, `anchor_discriminator`, partial signing), `Solana::SplToken`.

## Anchor Program (`turf-vault/`)

Separate project at `/Users/alex/projects/turf-vault/`. **v0.18.0**, Anchor 0.32.1.

- Program ID: `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ` (devnet — current, v0.18; deployed slot 465782911, 2026-05-31). `declare_id!` is cluster-gated — mainnet builds carry the `1111…1111` placeholder until the operator generates a mainnet keypair (see `MAINNET_LAUNCH.md` §3).
  - Superseded/orphaned devnet programs: `Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT` (the 2026-05-18 migration target, since superseded; ~4 SOL ProgramData rent locked under the Squads authority) and `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J` (upgrade authority lost; ~3.45 SOL of rent locked there). See the program-ID migration notes in `CLAUDE.md`'s TODO log.
- `VaultState` PDA `[b"vault"]` is a **zero-copy singleton** (~1515 bytes) holding the signer set, threshold, `paused` flag, the pinned `payout_mint` (USDC), the pinned `treasury_authority` (Squads vault PDA), and the 16-slot `accepted_currencies` registry. It holds **no pooled token balance**. Rails decodes it via hardcoded byte offsets in `vault.rb#read_vault_state`.
- IDL: committed at `config/turf_vault.idl.json`, SHA256-pinned via `EXPECTED_IDL_HASH` (`Solana::Config.verify_idl!`). Current v0.18 hash: `2d87b0935f5cd217b04a98153033c371d0b6f90018e9713acf3c3b44fe4db263`.
- USDC Mint (devnet test): `222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9` — registry **slot 0** (= `payout_mint`, the immutable settlement currency).
- USDT Mint (devnet test): `9mxkN8KaVA8FFgDE2LEsn2UbYLPG8Xg9bf4V9MYYi8Ne` — registry **slot 1**. (Mainnet builds pin Circle USDC `EPjFWdd5…Dt1v` + Tether USDT `Es9vMFr…wNYB`.) All amounts are `u64` at 6 decimals (1 USDC = 1_000_000).

### Instructions (18)

| Instruction | Auth | What it does |
|---|---|---|
| `initialize` | `INIT_AUTHORITY` (mainnet); any signer on dev | One-time singleton setup: create `VaultState`, pin `payout_mint`=USDC + `treasury_authority`, register USDC (slot 0) + USDT (slot 1), init their `op_rev` ATAs, lock in `signers[3]` + `threshold`. |
| `register_currency` | **2-of-3** | Add a mint to the next free `accepted_currencies` slot + init its `op_rev` ATA. Rejects duplicates / full registry. |
| `deactivate_currency` | **2-of-3** | Flip a slot `active=0` (slot/`op_rev` never reclaimed → `currency_idx` stable). |
| `pause` | **2-of-3** | Set `paused=1` → blocks **only** `enter_contest{,_with_token}` (everything else stays callable). |
| `unpause` | **2-of-3** | Set `paused=0`. No auto-unpause. |
| `create_user_account` | permissionless payer | Allocate `UserAccount` `[b"user", wallet]` with an on-chain-validated `username` (the wallet is *not* a signer → operator-funded onboarding). |
| `set_username` | **user-signed** | Overwrite the caller's username (re-runs `validate_username`; uniqueness/homoglyph checks stay off-chain). |
| `create_season` | **1-of-3** | Create `Season` `[b"season", id]` with an immutable per-entry `seed_schedule [u64;5]`. |
| `create_contest` | **1-of-3** payer + **creator** | Init `Contest` + `prize_pool` ATA and SPL-transfer the creator's USDC into the pool. `sum(payout_amounts) == prize_pool`. Operator-funded contests use the admin for both slots. |
| `set_contest_lock_time` | **1-of-3** | Set/clear `lock_timestamp` (v0.17 derived lock; `0`=no lock). Rejected once settled/cancelled or past `conclusion_timestamp`. |
| `set_contest_conclusion_time` | **1-of-3** | Set/clear `conclusion_timestamp` (v0.18); once chain time passes it, the lock time is final. |
| `enter_contest` | **user-signed** + **1-of-3** payer | Paid entry: SPL-transfer fee user-ATA → `op_rev` ATA, init `ContestEntry`, award seeds, bump `entry_fees`/`current_entries`. One path serves Phantom (user signs) + managed (server signs both slots). |
| `enter_contest_with_token` | **user-signed** + **1-of-3** payer | Token-funded entry: consume an `EntryTokenAccount` (no SPL transfer), award seeds. `currency_idx = 255` sentinel; does **not** bump `entry_fees` (intentional v1 gap). |
| `mint_entry_token` | **1-of-3** | Mint a pre-purchased free-entry voucher `[b"entry_token", owner, sequence]` (`source`: operator/Stripe/MoonPay). Not pause-gated. |
| `settle_contest` | **2-of-3** | Grade: per-winner SPL-transfer `prize_pool` → winner ATA (PDA-signed), update entry/user stats. `remaining_accounts` = triples `[user_account, entry, winner_ata]`. Cap = `sum(payouts) <= prize_pool`. |
| `cancel_contest` | **2-of-3** | Refund the full live `prize_pool` balance → creator ATA; status→Cancelled (entry fees stay operator revenue). |
| `close_contest` | **1-of-3** | Reclaim rent on a Settled/Cancelled contest: dust-sweep `prize_pool`→`op_rev` USDC, close both PDAs. |
| `sweep_operator_revenue` | **2-of-3** | Drain an `op_rev` ATA → treasury ATA (enforces `treasury_ata.owner == treasury_authority`). |

### Accounts / PDAs

| Account | Seeds | Purpose |
|---|---|---|
| `VaultState` | `[b"vault"]` (singleton) | Zero-copy: `signers[3]`, `threshold`, `paused`, `payout_mint`, `treasury_authority`, `accepted_currencies[16]`. No funds. |
| `AcceptedCurrency` | inline (1 of 16 slots in `VaultState`) | `{mint, op_rev_ata, kind, active}`. Slot 0=USDC, 1=USDT. |
| `UserAccount` | `[b"user", wallet]` | 133 B. `username` (on-chain master), `seeds`, stat counters (`entries`/`wins`/`cashes`/`total_won`). **No balance fields** (v0.16). |
| `Contest` | `[b"contest", contest_id]` (`contest_id = SHA256(Rails slug)`) | `prize_pool`, `entry_fee_by_currency[16]`, `entry_fees[16]` (revenue tally), `max_entries`/`current_entries`, `status`, `payout_amounts`, `lock_timestamp` (v0.17), `conclusion_timestamp` (v0.18). INIT_SPACE unchanged v0.16→v0.18 (timestamps carved from `_reserved`). |
| `ContestEntry` | `[b"entry", contest_id, wallet, entry_num u32 LE]` | `status` (Active→Won/Lost), `rank`, `payout`, `currency_idx` (`255` = token-funded). Up to 3 per user (Rails cap). |
| `EntryTokenAccount` | `[b"entry_token", owner, sequence u64 LE]` | Pre-purchased free-entry voucher. `source` (0=operator/1=Stripe/2=MoonPay), `consumed`. Discover via `getProgramAccounts` by owner. |
| `Season` | `[b"season", season_id u32 LE]` | Immutable `seed_schedule [u64;5]` (entry N → `seed_schedule[min(N,4)]`). |
| `prize_pool` ATA | `[b"prize_pool", contest_id]` (authority = `VaultState`) | Per-contest USDC prize pool; funded at create, paid at settle, refunded at cancel. |
| `op_rev` ATA | `[b"op_rev", mint]` (authority = `VaultState`) | Per-currency operator revenue; entry fees land here, swept to treasury. |

### Two-level multisig auth

- **1-of-3 vault signer** (`vault_state.is_signer(key)`) — routine ops: `create_contest` (payer), `set_contest_lock_time`, `set_contest_conclusion_time`, `close_contest`, `mint_entry_token`, `create_season`, and the **payer** slot of `enter_contest{,_with_token}`. Driven by the always-online Alex Bot server key.
- **2-of-3 multisig** (`vault_state.validate_multisig(admin, cosigner)`, distinct signers) — treasury ops: `settle_contest`, `cancel_contest`, `register_currency`, `deactivate_currency`, `sweep_operator_revenue`, `pause`, `unpause`.
- **User signature** required for `set_username` and the **user** slot of `enter_contest{,_with_token}` (the user must consent to spending from / consuming their own funds — OPSEC-004).
- `create_user_account` is permissionless (payer only); `initialize` is gated to `INIT_AUTHORITY` on mainnet builds.

Signers (`VaultState.signers`, threshold 2):
- Alex Bot (server) — `F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ`
- Alex (human Phantom, = `INIT_AUTHORITY`) — `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
- Mason — `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`

### Program Upgrades — Squads multisig (OPSEC-002, 2026-05-19+)

**`anchor deploy` no longer works.** The program upgrade authority is a Squads V4 2-of-3 multisig vault (`BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC`) — distinct from `VaultState`'s in-program multisig — not a single keypair. Every upgrade goes through the Squad. Running `anchor deploy` will fail because the Solana CLI signs as a single keypair that is no longer the upgrade authority.

Use `turf-vault/scripts/squad-upgrade.js` — it builds a buffer, sets the buffer authority to the Squad vault, then proposes + approves the upgrade tx through the Squad. See `turf-vault/CLAUDE.md` § "Deploying an upgrade" for the full step-by-step (1Password key refs included).

**Post-deploy IDL re-pin (mandatory)**: After every Squad upgrade, turf-monster MUST re-pin `EXPECTED_IDL_HASH` from the **freshly built** IDL — NOT `anchor idl fetch`. Squad upgrades run only the BPF `upgrade` instruction; they do NOT update the on-chain IDL account. `anchor idl fetch` therefore returns the stale pre-upgrade IDL.

```bash
# After deploying turf-vault:
cp /Users/alex/projects/turf-vault/target/idl/turf_vault.json \
   /Users/alex/projects/turf-monster/config/turf_vault.idl.json
cd /Users/alex/projects/turf-monster
shasum -a 256 config/turf_vault.idl.json   # → this is the new EXPECTED_IDL_HASH

# Set EXPECTED_IDL_HASH on Heroku BEFORE git push (assets:precompile runs verify_idl!):
heroku config:set EXPECTED_IDL_HASH=<sha> -a turf-monster

# Then commit + deploy
git add config/turf_vault.idl.json
git commit -m "Re-pin IDL after turf-vault vX.Y.Z deploy"
bin/deploy
```

`Solana::Config.verify_idl!` will refuse to boot — and to precompile assets — in production when the file's SHA256 ≠ `EXPECTED_IDL_HASH`. Running prod against a drifted IDL silently corrupts every Borsh decode.

### Multisig Settlement Flow
1. `Contest#grade!` scores entries and calls `settle_onchain!`
2. `settle_onchain!` calls `Vault#build_settle_contest` → creates a `PendingTransaction` with the partially-signed TX (2-of-3)
3. Admin visits `/admin/pending_transactions` (Treasury page)
4. Clicks "Co-sign" → Phantom signs as the second signer → TX submitted to Solana
5. On-chain: per-winner SPL transfer `prize_pool` PDA → winner USDC ATA (PDA-signed by `VaultState` seeds); contest status → Settled

> ⚠️ `grade!` marks the DB `settled` (writes `payout_cents` + TransactionLog credits) even if the on-chain settle PT is never cosigned — the sweeper deliberately skips treasury PTs, so no alert fires on an un-cosigned settle. Cosign promptly or winners stay unpaid on-chain.

## Navbar Balance

`display_balance` helper shows the user's on-chain USDC ATA balance (cached 60s) for **all** wallet types — there is no DB-balance tracking in v0.16. Falls back to 0 on error. The `/admin/usdc_balance` JSON endpoint (used by `refreshBalance()` JS) follows the same logic and is the one `AdminController` action excluded from `require_admin` (self-only; audit #27). Both use `fetch_user_usdc` → `Vault#fetch_wallet_balances(current_user.solana_address)`.

**Balance refresh system**: `refreshBalance()` fetches `/admin/usdc_balance` and updates all `[data-balance-display]` elements. `refreshBalanceDelayed(ms)` waits (default 10s) then calls `refreshBalance()` — spins the navbar refresh icon (`[data-balance-refresh]`) during the wait. Called automatically after Solana operations (faucet, contest creation, payout). Manual refresh button (circular arrows icon) next to the balance in navbar (desktop + mobile).

## Wallet Types

- **Managed (web2)**: Server generates an Ed25519 keypair and stores the secret encrypted (via `MANAGED_WALLET_ENCRYPTION_KEY`), signing on behalf of the user. USDC still lives in the user's own ATA (self-custody model; formerly "custodial").
- **Phantom (web3)**: User connects the Phantom browser extension (or any Wallet-Standard wallet) and signs transactions directly.

## Hard Escrow Contest Creation (Phantom-driven, 2026-05-18+)

Contest creation transfers the prize-pool USDC from the creator's Phantom wallet into the **per-contest `prize_pool` PDA** `[b"prize_pool", contest_id]` (authority = `VaultState`) — real hard escrow, not just a number on a PDA, and **not** a shared vault balance. Dual-signer: the admin bot pays SOL rent, the creator's Phantom signs the USDC transfer.

The on-chain TX completes **before** the DB row is created, so the database always reflects committed on-chain state.

1. Admin fills form + submits → `POST /contests` (`ContestsController#create`)
   - Click-time prechecks: on-chain `Contest` PDA must not exist; creator's USDC must cover the prize pool. Insufficient-USDC modal includes a "Mint $500 Test USDC" recovery button.
   - Server builds a partially-signed `create_contest` TX (admin pays SOL rent + signs as `payer`; creator will sign as `creator` for the USDC transfer). Returns the partial TX + a signed `params_token`.
2. Client: `phantom.signTransaction(tx)` → `connection.sendRawTransaction()` → wait for confirmation.
3. `POST /contests/finalize` (`ContestsController#finalize`) — collection route, no `:id`.
   - Verifies the TX via `verify_solana_transaction!` (OPSEC-010 — matches the `create_contest` discriminator + expected accounts).
   - Creates the DB row with `skip_onchain_callback = true` so the legacy `Contest#create_onchain!` after_create callback doesn't double-spend.

### Legacy server-only fallback

`Contest#create_onchain!` (via `after_create`) is preserved for Rails console / scripts / tests (`Rails.env.test?` auto-skips). The old `POST /contests/:id/prepare_onchain_contest` + `confirm_onchain_contest` endpoints still exist for backward compat and are referenced by `e2e/onchain.spec.js` — the production UI no longer uses them.

## Onchain Entry — three payment rails, one confirm gate

All three end at `Entry#confirm!` / `#confirm_onchain!`, which enforce the payment-proof (`tx_signature`), lock-time, exactly-`picks_required`, no-locked-games, per-user-limit, and sybil checks.

1. **Managed-wallet token-consume** — managed user with an `EntryTokenAccount`: `Vault#enter_contest_with_token` signs with the server-held keypair; consumes the token (no USDC moves), awards seeds, then `bust_entry_tokens_cache!`.
2. **Managed-wallet USDC** — `Vault#enter_contest` signs **both** the admin (payer) and user (custodial keypair) slots and broadcasts directly. SPL transfer user-ATA → `op_rev` ATA. There is no DB-balance or PDA-balance deduction — neither exists in v0.16.
3. **Phantom-direct** — `prepare_entry` builds a partial-signed `enter_contest` TX (admin = payer, user slot left for Phantom) + creates a `PendingTransaction`; client signs → `sendRawTransaction` → `confirm_onchain_entry` re-derives the entry PDA server-side, runs `TxVerifier`, then `Entry#confirm_onchain!`. `recover_pending_entry` resolves entries stranded by a mid-flight refresh (also TxVerifier-gated — Lazarus audit #1).

(There is one unified `enter_contest` instruction — the old `enter_contest_direct` was removed in v0.16. Phantom users' navbar USDC decreases live after the transfer; no DB balance is tracked for any wallet type.)

## Seeds System (On-Chain)

Seeds are awarded on-chain per the active **Season**'s `seed_schedule` (turf-vault v0.11.0+). Default schedule is `[25, 19, 14, 10, 7]` — entry index 0 → 25 seeds, index 4+ clamps to slot 4. No DB column for the seeds count — read from the `UserAccount` PDA via `Solana::Vault#sync_balance`. UI-derived levels: `level = seeds / 100 + 1` (`SEEDS_PER_LEVEL = 100`); class methods `User.level_for(seeds)`, `seeds_toward_next_level(seeds)`, `seeds_progress_percent(seeds)`. The active season is tracked in `SeasonConfig.current_season_id` (Rails singleton); the on-chain `Season` PDA lives at `[b"season", season_id_le]`. Compute an entry's award via `Solana::Vault.new.seeds_for_entry(entry_num)`. Progress-bar partial `_seeds_bar.html.erb` (navbar via `_user_nav` + contest show via `_slate_progress_xp`); level-up confetti; "Free Entry Earned 🎟️" badge in the entry-confirm modal (cosmetic — operator mints actual `EntryTokenAccount` PDAs via `/admin/free_entries`). `User#level` column persisted via `update_level_from_seeds!` (`PATCH /account/update_level`).

> Cross-doc note: `CLAUDE.md` currently says "65 seeds per entry" — that figure is **stale**; the per-season schedule above (matching `vault.rb`) is authoritative.

## Rake Tasks (`lib/tasks/solana.rake`)

- `solana:init_vault` — initialize the vault on devnet. Args `INIT=true SIGNERS=addr1,addr2,addr3 THRESHOLD=2` (optional `TREASURY=<squads_vault_pda>`, defaults to `SOLANA_SQUADS_VAULT_PDA` then the hardcoded Squads vault). OPSEC-013-gated in production. There is no `force_close` arg — the `force_close_vault` instruction was removed in v0.16; teardown = redeploy the program.
- `solana:health` — pre-flight before any cluster flip: genesis-hash match + program-exists-on-RPC + IDL-hash match. Exits non-zero on mismatch.
- `solana:idl_hash` — print the committed IDL's SHA256 (the value for `EXPECTED_IDL_HASH`).
- `solana:verify_idl` — run `verify_idl!` against the committed IDL.
- `solana:airdrop` — airdrop SOL to admin.
- `solana:check_balance` / `solana:check_admin_balance` — read on-chain SOL/USDC balances.
- `solana:mint_usdc` — mint test USDC to the admin ATA (`AMOUNT=<dollars>`, default 100). **Devnet only — hard-aborts in production (OPSEC-020).**
- `solana:fund_wallets` — fund a set of wallets (dev bring-up).
- `solana:generate_keypair` / `solana:test_encryption` / `solana:reencrypt_managed_wallets` — managed-wallet key tooling (the last rotates ciphertext to the current `MANAGED_WALLET_ENCRYPTION_KEY`).
- `solana:reconcile` — run `Solana::Reconciler` over all users (on-chain account-presence / state checks; no balance reconciliation — there are no custodial balances).
- `solana:reconcile_contest CONTEST=<slug>` — compare an on-chain contest's entry count + slot-0 `entry_fees` against the DB.

## Public faucet endpoint

`/faucet` is a public route — GET renders a marketing page; POST mints test USDC to the requester's wallet via `Vault#mint_spl(amount_lamports, mint: Solana::Config::USDC_MINT, to: wallet)`. Used by the "Mint $500 Test USDC" recovery button in the insufficient-USDC modal during Phantom-driven contest creation. `FaucetController#claim` mints via `Vault#mint_spl` directly (not the `solana:mint_usdc` rake task) and guards itself: it raises "Faucet is production-disabled" when `Rails.env.production?` and requires `Config.devnet?`.

## Solana Auth Security

- **SIWS / nonce replay prevention**: Solana sign-in nonces include a timestamp with an enforced 5-minute expiry; the nonce is deleted from the session before verification (delete-before-verify) to prevent replay. Signature verification is host-bound (`Solana::AuthVerifier`, OPSEC-018).
- **TX verification**: `Solana::TxVerifier` binds a submitted signature to the expected instruction + signer + server-re-derived PDA before any DB state is credited (OPSEC-010).

## Error namespace

turf-vault custom errors start at **6000** (`errors.rs`). Anchor framework **3000-range** errors (e.g. 3012 `AccountDidNotDeserialize`) signal **schema drift** between the deployed program and an on-chain account — i.e. an IDL/layout mismatch — **not** a vault error. Key codes: `ContestNotOpen` 6003, `ContestAlreadySettled` 6006, `SettlementOverflow` 6008, `ContestNotCancellable` 6029, `ContestLocked` 6034, `ContestConcluded` 6035. Several codes (6011/6012/6017/6019/6028) are retired-but-kept for numbering stability.
