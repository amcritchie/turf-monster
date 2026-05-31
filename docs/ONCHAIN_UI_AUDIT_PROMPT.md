# Session Prompt — On-chain UI Review + Pre-Mainnet Vulnerability Audit

**Created**: 2026-05-28 (after the v0.16 prod deploy)
**Use**: Paste the body of this file into a fresh Claude Code session in `~/projects/turf-monster`.

---

## Mission

Run a full review of every UI surface in turf-monster that touches the on-chain v0.16 contract, look for vulnerabilities and inconsistencies, and produce a punch-list ranked by severity. Goal: green-light the paused mainnet first deploy (task #12) once the punch-list is closed.

This is a defensive security review of code I own. Look for OWASP-style bugs (XSS, CSRF, SSRF, IDOR), Solana-specific issues (replay, PDA confusion, treasury authority bypass, IDL drift, account-not-checked-as-signer), and product-shape gaps (idempotency, race conditions, error UX).

---

## State as of last session (2026-05-28)

**Production (Heroku turf-monster):**
- Just released v114 — v0.16 contract is live on devnet prod
- `SOLANA_PROGRAM_ID = EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`
- `EXPECTED_IDL_HASH = 78a37c029ae9b1292015fe99db03ff6d89a89233ed9317f6b524a287620d3c48`
- `SOLANA_NETWORK = devnet`
- `SOLANA_RPC_URL` = Helius devnet endpoint (in 1Password at `agent.helius` field "Devnet RPC URL")
- `solana:health` 4/4 green
- `BYPASS_IDL_CHECK` unset (full verification active)

**Code state:**
- Full Rails suite: 462/462 green
- Playwright chromium E2E: 53/53 green (2 `@devnet` skips by design)
- `solana-studio` gem at 0.4.3 (downstream monkey-patch removed)

**Remaining pending tasks:**
- **#11** Self-custody export + prove-custody flow (bigger design piece — out of scope for this audit)
- **#12** Mainnet first deploy (paused on Alex Bot SOL float per the runbook; audit unblocks this)

**Other useful context:**
- v0.16 spec doc: `~/projects/turf-vault/docs/v0.16-spec.md`
- v0.16 error codes 6023–6033: `~/projects/turf-vault/programs/turf_vault/src/errors.rs`
- ErrorInterpreter Rails-side mappings: `app/services/solana/error_interpreter.rb`
- The /contract transparency page (built by Shannon yesterday): `app/views/contract/`
- Past audits to model the format on: `docs/SECURITY_AUDIT_2026_05_23.md`, `docs/REFACTOR_AUDIT_2026_05_23.md`

---

## What to audit (scope)

### A. User-facing on-chain flows

1. **Token purchase → mint**
   - `app/views/modals/auth/_tokens.html.erb` (the in-modal buy flow)
   - `app/views/tokens/processing.html.erb` (Stripe-return processing card)
   - `app/controllers/tokens_controller.rb` (`#buy`, `#stripe_checkout`, `#processing`, `#status`, `#dev_mint`)
   - `app/jobs/token_purchase_job.rb` (mint loop + idempotency)
   - `app/jobs/stripe_deposit_job.rb`, `app/jobs/moonpay_deposit_job.rb` (other deposit paths)
   - `app/webhooks/` — Stripe webhook entry points
   - Look for: replay attacks on session_id; ability to redeem a Stripe session for a different user; race between webhook + manual /tokens/status poll; what happens if mint fails after Stripe charge succeeded

2. **Contest entry**
   - `app/views/contests/_turf_totals_board.html.erb` (the giant selection-board partial; entry-flow JS lives here)
   - `app/controllers/contests_controller.rb` (`#toggle_selection`, `#enter`, `#enter_with_token`, `#prepare_onchain_contest`)
   - `app/services/solana/vault.rb` — `build_enter_contest` (web3 USDC ATA path) and `build_enter_contest_with_token` (web2 entry-token path)
   - Look for: hold-button race conditions (we hit one yesterday with re-entry guard); modal-state confusion when user opens/closes mid-flow; client-side eligibility bypass; double-entry; entry-fee tampering via DOM manipulation

3. **Signup → on-chain UserAccount**
   - `app/controllers/omniauth_callbacks_controller.rb` (Google → managed wallet → on-chain UserAccount)
   - `app/services/solana/auth_verifier.rb` (Phantom signature → session adapter)
   - `app/jobs/create_onchain_user_account_job.rb`
   - `app/models/user.rb` — `#ensure_username`, `#managed_wallet?`, `#solana_connected?`
   - Look for: username collisions / squatting; signature replay across dApps (OPSEC-018 should prevent — verify); managed-wallet key encryption rotation; Google email-not-verified bypass

4. **Wallet/balance display**
   - `app/views/account/` (the /account page that shows balance + entry tokens)
   - `app/views/wallet/` (the /wallet page)
   - `User#entry_token_balance`, `User#cached_entry_tokens`, `User#display_balance`
   - `app/services/solana/vault.rb#list_entry_tokens`, `#get_usdc_balance`, `#read_user_account`
   - Look for: cross-user balance leakage; cache key collisions across users; stale-cache vulnerabilities; rate-limit handling (we saw silent 0-balance fallbacks)

5. **Operator admin paths**
   - `app/controllers/admin/` — anything that calls into `Solana::Vault`
   - `app/views/admin/`
   - `app/views/contests/generator.html.erb`
   - The v0.16 operator instructions: `register_currency`, `deactivate_currency`, `lock_contest`, `unlock_contest`, `cancel_contest`, `settle_contest`, `close_contest`, `sweep_operator_revenue`, `mint_entry_token`, `pause`, `unpause` (NOTE: `lock_contest`/`unlock_contest` superseded by the derived time-lock primitive in turf-vault v0.17/v0.18 — locking now flows through the Phantom-signed `prepare_lock_time`/`confirm_lock_time` + `prepare_conclusion_time`/`confirm_conclusion_time` setting `lock_timestamp`/`conclusion_timestamp`)
   - Look for: routes reachable by non-admins (the `require_admin` callback IS set per the prelaunch audit, but re-verify); CSRF on POST/PATCH ops; authority confusion (INIT_AUTHORITY vs MULTISIG_SIGNERS); operator dry-run vs broadcast confusion

### B. Solana plumbing

6. **Vault client layer**
   - `app/services/solana/vault.rb` — every public method
   - `app/services/solana/config.rb` — env-var fall-throughs
   - `app/services/solana/error_interpreter.rb` — coverage gaps for any code 6000–6033
   - `config/initializers/solana_network_alignment.rb` (OPSEC-039 boot guard)
   - `config/initializers/solana_idl_verification.rb` (OPSEC-014 boot guard)
   - `config/initializers/solana_keypair_safety.rb`
   - Look for: signature verification gaps; missing PDA recheck; account-not-as-signer; instruction discriminator drift; assumption that `getAccountInfo` returning nil = "account doesn't exist" when it could mean RPC error

7. **The Sidekiq stale-env guard** (we shipped yesterday)
   - `Solana::Vault.ensure_program_id_live!` — called from `TokenPurchaseJob#perform`
   - Should it ALSO run in `enter_contest`, `settle_contest`, every operator op? Audit answer.

8. **IDL pin + boot guards**
   - Are there code paths that fire RPC calls BEFORE the boot guards have run? (e.g., eager Rails initializers, console runners, rake tasks)
   - Should `bin/rails solana:health` be wired into the deploy script (`bin/deploy`)?

### C. Transparency page

9. **`/contract` page** (`app/views/contract/`)
   - Reads from Heroku env at render time — verify any rendered values are correct vs the actually-deployed program
   - Does it leak operator-private info to non-admins?
   - Are the binary-size + rent numbers still accurate for v0.16?

---

## Suggested approach

Spawn the specialized agents in parallel for the first pass:

- **Jasper** (Dev Blockchain Expert) — A. all on-chain flows, B. Solana plumbing. Output: ranked finding list.
- **Carl** (Dev Backend Expert) — A. controllers + jobs + caching, idempotency analysis. Output: ranked finding list.
- **Shannon** (Dev UI Expert) — A. modal flows, entry-flow JS, /contract page UI. Output: UX + accessibility + race-condition findings.
- **Avi** (Product Owner) — synthesize all three findings into a punch-list for the mainnet launch. Sign off or send back.

Send all four in a single message so they run concurrently. Brief each on the v0.16 contract shape + Helius RPC + the recent state-pollution + cache patterns. Give them this prompt as background plus their specific scope.

Then read the punch-list together and:
- Fix anything ranked critical/high inline
- Open tracked tasks for medium/low
- Update CLAUDE.md with anything subtle that bit us

---

## Definition of done

- [ ] Ranked finding list (C/H/M/L), with file:line references
- [ ] All critical + high findings patched (or have a tracked task explaining the gate)
- [ ] Boot guards verified to cover every on-chain entry point
- [ ] `bin/rails solana:health` wired into `bin/deploy` (or documented as a manual step)
- [ ] CLAUDE.md and `docs/SOLANA.md` reflect any subtle gotchas learned
- [ ] Final memory entry summarizing the audit
- [ ] Task #12 (mainnet first deploy) unblocked: an explicit go/no-go in writing

---

## Things to NOT do without asking

- Push to Heroku (production deploy) — gated on go/no-go decision after the audit
- Touch the upgrade authority or Squads vault config
- Modify the `EXPECTED_IDL_HASH` env var on Heroku
- Delete any of the migration files in `db/migrate/`
- Re-deploy turf-vault (the contract) — that's a separate flow with its own runbook

If anything feels destructive or irreversible, ask first. Per the existing CLAUDE.md: "measure twice, cut once."
