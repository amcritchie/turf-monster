# Tests to Add (Audit Tier 2 #14)

> **ARCHIVE-ONLY BACKLOG SNAPSHOT.** This file captured the May 2026 test punch
> list. Use `docs/TEST_COVERAGE_STATUS.md` for current test orientation and only
> return here for historical detail.

> **Status (2026-05-23):**
> - **Priority 1** (Vault client boundary ~20 tests) — ⏳ **NOT STARTED at Rails unit level.** `test/services/solana/vault_test.rb` does not exist yet. Devnet smoke spec (`e2e/devnet-smoke.spec.js`, ~890 lines) covers happy paths end-to-end at the Playwright level, but Rails unit coverage for edge cases (insufficient selected currency, locked contest, lamports-for-rent shortfall, sync of non-existent PDA/ATA) is still missing.
> - **Priority 2** (Reconciler ~15 tests) — ⏳ **NOT STARTED.** `test/services/solana/reconciler_test.rb` does not exist. The Sidekiq-cron job is wired and writes to `ErrorLog` / `RECONCILER_ALERT_WEBHOOK`, but divergence-detection logic is not unit-tested.
> - **Priority 3+** (Contest grading, settlement, edge cases) — ⏳ **PARTIAL.** `test/models/contest_test.rb` exists but doesn't cover all listed scenarios. Devnet smoke spec covers grade-then-settle end-to-end.
> - Devnet integration tests are tracked separately in [`DEVNET_INTEGRATION_TESTS_TO_ADD.md`](DEVNET_INTEGRATION_TESTS_TO_ADD.md).
>
> The priorities below are historical context. Use
> `docs/TEST_COVERAGE_STATUS.md` before reviving any item.

The 2026-05-17 ecosystem audit identified turf-monster's test count (97 tests, 264 assertions) as low for the risk profile (real Solana tokens, 2-of-3 multisig settlement, on-chain entry and wallet/ramp flows). The audit's target: ~200 tests, roughly doubling current coverage, concentrated on the Solana boundary.

This file was the concrete punch list for the May 2026 audit. If an item is
revived, re-check the current code first, then execute in a focused batch and
run the relevant Rails or Playwright tests before committing.

## Priority 1 — Vault client boundary + on-chain accounting (~20 tests)

`test/services/solana/vault_test.rb` (create if absent)
- `Vault#sync_balance` for managed wallet → reads `UserAccount`, returns seeds plus back-compat balance keys
- `Vault#sync_balance` for non-existent `UserAccount` PDA → returns nil/zero shape without raising
- `Vault#fetch_wallet_balances` for existing USDC/USDT ATAs → returns per-currency cents
- `Vault#fetch_wallet_balances` for missing ATAs → returns zero balances without creating DB balance state
- `Vault#ensure_ata` idempotently creates/returns an ATA
- `Vault#mint_entry_token` → creates one unconsumed `EntryTokenAccount`
- `Vault#list_entry_tokens` → decodes consumed/unconsumed tokens for an owner
- `Vault#enter_contest_with_token` (managed mode) → consumes token, creates ContestEntry, awards seeds
- `Vault#enter_contest` (managed USDC mode) → transfers user ATA funds to `op_rev`, creates ContestEntry
- `Vault#enter_contest` when contest is locked → raises, no on-chain call
- `Vault#build_enter_contest` (Phantom mode) → builds correct partial TX with user as signer and admin cosign path
- Currency selection: USDT rejected when contest `accepts_usdt` is false
- Insufficient selected currency → raises/interprets a user-facing blocker without mutating DB state

## Priority 2 — Reconciler divergence detection (~15 tests)

`test/services/solana/reconciler_test.rb` (create if absent)
- `Reconciler#reconcile_user` for fully-synced user → returns balance, no discrepancies
- `Reconciler#reconcile_user` with missing on-chain account → `discrepancies` contains `:missing_onchain_account`
- `Reconciler#reconcile_user` with RPC error → `discrepancies` contains `:error` with class + message
- `Reconciler#reconcile_user` for non-connected user → no-op (returns nil), no discrepancy
- `Reconciler#reconcile_contest` with matching entry counts → no discrepancy
- `Reconciler#reconcile_contest` with `entry_count_mismatch` → contains DB + on-chain counts
- `Reconciler#reconcile_contest` with `entry_fees_mismatch` → contains DB + on-chain lamports
- `Reconciler#reconcile_contest` for non-onchain contest → no-op
- `Reconciler#reconcile_all` aggregates across all users with `solana_address`
- `Reconciler#reconcile_all` continues iterating after a per-user failure
- `Reconciler#log_discrepancies` creates ErrorLog rows with type in `message`
- `Solana::ReconcileJob#perform` calls `Reconciler#reconcile_all`
- `Solana::ReconcileJob#perform` posts to webhook on discrepancies (mock Net::HTTP)
- `Solana::ReconcileJob#perform` skips webhook when env var absent
- `Solana::ReconcileJob#perform` swallows webhook delivery failures (logs but doesn't raise)

## Priority 3 — Contest grading edge cases (~25 tests)

`test/models/contest_test.rb` (existing — extend)
- `Contest#grade!` with ties → tied entries get same rank, payouts split evenly
- `Contest#grade!` with all entries `abandoned` → settles to no payouts
- `Contest#grade!` with mixed active + abandoned → only active counted in payout
- `Contest#grade!` called on already-`settled` → raises "Contest is already settled"
- `Contest#grade!` mid-settlement RPC failure → contest stays in `locked` (no half-state)
- `Contest#fill!(users:)` with N=3 → creates 3 entries (one per user)
- `Contest#fill!` with N=99 → creates 99 entries
- `Contest#fill!` skips users with already-active entries (no dupes)
- `Contest#fill!` rejects when matchups < `picks_required` (raises)
- `Contest#jump!` → simulates games, calls grade!, ends in `settled`
- `Contest#jump!` from `:pending` → first opens, then settles
- `Contest#reset!` from `:settled` → entries destroyed, contest back to `:open`
- `Contest#reset!` from `:locked` → entries destroyed, contest back to `:open`
- `Contest.target` returns highest-rank open contest
- `Contest.target` returns nil when no contests are open
- Payout tier validation: Standard contest sum == prizes
- Payout tier validation: Large contest sum == prizes
- Settlement payout calculation for tied 1st (split 50/50)
- Settlement payout calculation for tied 1st + 2nd (3-way split top tier)
- Onchain settlement creates `PendingTransaction` with status `:pending`
- Onchain settlement skipped when `onchain_settled` already true (idempotent)
- `Contest#active_entry_count` excludes `:cart` and `:abandoned`
- `Contest#locks_at` aliases `starts_at`
- `Contest#lock_time_display` formats correctly for far-future + past times
- `Contest#picks_required` always returns 6

## Priority 4 — Settlement-failure recovery paths (~10 tests)

`test/models/pending_transaction_test.rb` (create if absent)
- Insufficient cosigner signatures (only 1 signed) → status stays `:pending`
- Both signers but cosigner not in vault `signers[]` → on-chain rejection bubbles up
- Same-signer-twice (admin + admin) → on-chain rejection
- Timeout: PendingTransaction older than 24h → background sweep marks `:expired`
- Re-submission after `:failed` → new PendingTransaction created (not mutation)
- `target` polymorphic association resolves to Contest correctly
- `serialized_tx` round-trips through base64 without corruption
- `metadata` jsonb stores per-tx-type fields (settle, entry, wallet-export/ramp flows)

## Priority 5 — SSO wallet-only error path (~5 tests)

`test/integration/sso_wallet_only_test.rb` (create if absent)
- Wallet-only user (no email) attempts SSO → friendly error, not 500
- Wallet-only user clicks "Continue as" in hub navbar → not shown the button
- Hub sends sso_email present but `sso_source` matches satellite → "Continue as" hidden
- SSO from hub with valid email → user created on satellite with `role: viewer`
- SSO with email already in satellite DB → links to existing user, doesn't duplicate

## Priority 6 — Contract tests for test_solana_stubs.rb (~5 tests)

`test/initializers/test_solana_stubs_test.rb` (create if absent)
- `MockTxSignature` prefix matches what `e2e/rpc-mock.js` generates (read both, assert equal)
- Stubbed `Solana::Client#get_transaction` with mock sig returns successful shape
- Stubbed call with real sig falls through to real RPC (not stubbed)
- The stub registers only in `RAILS_ENV=test` (not dev/prod)
- Removing the stub mid-test allows real RPC calls again

## Priority 7 — Misc Solana::SessionAuth shim (~5 tests)

`test/controllers/concerns/solana/session_auth_test.rb` (create if absent — now that the gem owns the verifier, only the app shim needs tests)
- Shim deletes both `:solana_nonce` and `:solana_nonce_at` from session BEFORE delegating
- Shim delegates to gem with correct keyword args
- Replay attempt (same nonce reused) → second call has no nonce in session → raises
- Stale nonce (now - nonce_at > 5 min) → raises (via gem)
- Bad signature → raises (via gem)

## How to execute

```bash
cd ~/projects/turf-monster
PATH="/opt/homebrew/opt/ruby@3.1/bin:$PATH" bin/rails test  # baseline (~97 runs)
# Pick a Priority block, write its tests, run incrementally
PATH="/opt/homebrew/opt/ruby@3.1/bin:$PATH" bin/rails test test/services/solana/vault_test.rb
# When green, commit. Keep batches small (1-2 priority blocks per commit).
```

Target end state: ~200 tests, all 7 priorities covered. Drop this file once done (or move to `docs/TESTS_COVERAGE.md` as a static reference).

## Why this file exists

The audit recommended adding ~100 tests in this area. Writing the tests carefully takes more focused time than the rest of Tier 2; rather than partial coverage shipped sloppily, this list queues the work concretely so a fresh session can execute end-to-end without re-deriving what's missing.
