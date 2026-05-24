# Devnet v0.15.0 Rehearsal Runbook

End-to-end rehearsal of the mainnet launch ritual against devnet. Do this **before** running `MAINNET_LAUNCH.md` so you catch tooling / process gaps in a no-money environment.

Estimated time: ~45 minutes (most of it waiting on Squads cosign + Solana finality).

---

## Goal

Validate that the v0.15.0 mainnet ritual works:
- Squads-mediated upgrade lands cleanly
- VaultState gains the `paused` field (force_close + reinit migration path works)
- Alex's Phantom can call `initialize` (or, on devnet, any signer can since the H1 check is mainnet-gated)
- Pause/unpause UI works end-to-end via Phantom cosign
- $100 daily cap fires on real RPC
- IDL re-pin doesn't break Rails boot

If anything's flaky on devnet, it'll be flaky on mainnet too — fix it here.

---

## Pre-flight

- [ ] Both repos pulled latest from `origin/main`:
  ```bash
  cd /Users/alex/projects/turf-vault && git pull origin main
  cd /Users/alex/projects/turf-monster && git pull origin main
  ```
- [ ] Alex Bot devnet wallet has ≥ 3 SOL for the program upgrade
- [ ] Mason devnet wallet has ≥ 0.05 SOL for cosigning
- [ ] `~/.config/solana/id.json` exists and is funded (the test wallet for any direct ops)

---

## 1. Build v0.15.0 (devnet build — DEFAULT features, not mainnet)

```bash
cd /Users/alex/projects/turf-vault
anchor build
shasum -a 256 target/deploy/turf_vault.so
```

- [ ] Build succeeds. Record the SHA for later comparison.
- [ ] `target/idl/turf_vault.json` exists.

---

## 2. Squads-mediated upgrade to devnet

```bash
solana program write-buffer target/deploy/turf_vault.so --url devnet
# → records BUFFER_ADDR

solana program set-buffer-authority <BUFFER_ADDR> \
  --new-buffer-authority BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC --url devnet

ALEX_BOT_KEY=$(op item get agent.solana    --vault agents --fields "private key" --reveal) \
MASON_KEY=$(op item get agent.mason.solana --vault agents --fields "private key" --reveal) \
  node scripts/squad-upgrade.js <BUFFER_ADDR>
```

- [ ] All three Squads stages complete (propose → approve ×2 → execute)
- [ ] `solana program show Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT --url devnet` shows a recent "Last Deployed In Slot"

---

## 3. force_close + re-initialize (schema migration)

The v0.14 → v0.15 VaultState layout added `paused: bool` (1 byte). Anchor refuses to deserialize the old layout into the new struct, so the existing vault must be force-closed and re-initialized.

```bash
cd /Users/alex/projects/turf-monster

# Force close (2-of-3 — Mason will need to cosign in 1Password)
bin/rails solana:init_vault FORCE_CLOSE=true

# Re-init (any signer can — H1 hardening is mainnet-gated)
bin/rails solana:init_vault INIT=true \
  SIGNERS=F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR \
  THRESHOLD=2
```

- [ ] Force close confirms (`solana account FYBTB5pwoSxN4CF5M45gW3e8hwMNFit6phbgyd4vpWAn --url devnet` returns "account not found" briefly)
- [ ] Init succeeds; same VaultState PDA address now exists with new size (235 bytes)

> **User decision (2026-05-23)**: skip the per-user `migrate_user_account` step. Fresh restart preferred over migrating existing devnet user balances.

---

## 4. Re-pin IDL hash

```bash
cp /Users/alex/projects/turf-vault/target/idl/turf_vault.json \
   /Users/alex/projects/turf-monster/config/turf_vault.idl.json

cd /Users/alex/projects/turf-monster
NEW_HASH=$(shasum -a 256 config/turf_vault.idl.json | awk '{print $1}')
echo "$NEW_HASH"

# Set in local .env (dev override of devnet)
echo "EXPECTED_IDL_HASH=$NEW_HASH" >> .env.local   # or wherever you keep dev env

# Restart Rails so the new IDL constant loads
```

- [ ] `bin/rails runner 'puts Solana::Config.idl_hash'` returns `$NEW_HASH`

---

## 5. Run the automated smoke test

```bash
bin/rails runner bin/devnet-v0.15-validate
```

Expected output:
```
turf-vault v0.15.0 devnet validation
…
  [1] Local IDL exists at config/turf_vault.idl.json… OK
  [2] EXPECTED_IDL_HASH set and matches the local IDL… OK
  [3] IDL contains all v0.15.0 instructions (pause, unpause)… OK
  [4] VaultState PDA exists on-chain… OK
  [5] VaultState decodes at v0.15.0 layout (paused field present)… OK
  [6] Vault is currently unpaused (paused: false)… OK
  [7] Multisig signer set matches config… OK
  [8] Multisig threshold matches config (2)… OK
  [9] Mints match config (USDC + USDT)… OK
  [10] build_pause_vault returns a base64 partial TX… OK
  [11] build_unpause_vault returns a base64 partial TX… OK
  [12] Any existing UserAccount is at v0.15.0 layout (113 → 129 bytes)… OK
  [13] Solana::Vault#sync_balance round-trips for the admin wallet… OK

✓ All 13 checks passed.
```

- [ ] All 13 checks pass. Any failure = stop and debug before proceeding to manual tests.

---

## 6. Manual end-to-end UI test (Phantom required)

```bash
bin/rails server -p 3001
```

Visit `http://localhost:3001` in a Phantom-equipped browser on devnet.

### 6a. Vault State page renders

- [ ] Go to `/admin/vault_state` — page shows "✓ ACTIVE" badge + vault details
- [ ] Admin dropdown does NOT show "Vault Init" badge (vault is initialized)

### 6b. Pause works

- [ ] On `/admin/vault_state`, enter reason "rehearsal pause"
- [ ] Click "🚨 Connect Phantom + PAUSE"
- [ ] Confirm dialog appears with the reason
- [ ] Phantom prompts → sign → submit
- [ ] Page reloads, shows "🚨 PAUSED" badge
- [ ] Admin dropdown shows "Vault State 🚨 PAUSED"

### 6c. Paused vault rejects deposit

- [ ] Connect a wallet with $5 USDC on devnet
- [ ] Try to deposit — TX fails with `VaultPaused` (6018)
- [ ] Rails error log captures the failure cleanly (no 500)

### 6d. Unpause works

- [ ] `/admin/vault_state` → click "Connect Phantom + Unpause"
- [ ] Phantom signs → submits → page reloads
- [ ] Badge flips back to "✓ ACTIVE"

### 6e. $100 daily cap fires

- [ ] Deposit $200 USDC into a test wallet
- [ ] Withdraw $100 — succeeds
- [ ] Try to withdraw $1 more — TX fails with `WithdrawDailyCapExceeded` (6019)
- [ ] Wait 24h… OR write a one-shot script that sets `daily_window_start` backdated to verify rollover (out of scope for normal rehearsal; documented in turf-vault CHANGELOG)

---

## 7. Sign-off

- [ ] All automated checks green
- [ ] All manual UI flows worked
- [ ] No surprises (timeouts, RPC errors, Phantom quirks, etc.)
- [ ] Tooling friction documented (e.g. "Mason's cosign took 8 minutes because…")

If everything's green, you're cleared to run `MAINNET_LAUNCH.md`. The mainnet ritual is identical except:
- Build with `--features mainnet`
- Alex must sign initialize via Phantom (H1 enforces INIT_AUTHORITY)
- Mints baked into the binary (Circle USDC + Tether USDT)
- Real money, real Stripe live keys, real monitoring
