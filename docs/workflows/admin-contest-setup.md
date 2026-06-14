# Workflow: admin-contest-setup

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-verify on edit — line numbers drift on refactor.
>
> **Refresh status:** This workflow has been partially refreshed for the
> current self-custody `enter_contest` contract, but the line-number citations
> should still be re-verified before using it as an implementation map.

**Trigger:** Operator (admin) opens the app to spin up a brand-new on-chain contest and enter it themselves.
**Actors:** Admin (Phantom wallet) / Phantom / Rails / Solana RPC / turf-vault Anchor program / Squads (only if the vault has never been initialized on this program).
**Outcome:** New on-chain `Contest` PDA funded with the prize pool; matching DB `Contest` row; admin's `Entry` PDA created + DB entry `active`; admin's `UserAccount` PDA seeded.
**Preconditions:**
- Admin has `role == "admin"` (`app/models/user.rb:91-93`) and a linked Phantom wallet (`web3_solana_address`). Admins are web3-only by policy — `User#generate_managed_wallet!` early-returns for admins (`app/models/user.rb:237-244`, OPSEC-044).
- `EXPECTED_IDL_HASH` matches `config/turf_vault.idl.json` (verified at boot — `Solana::Config#verify_idl!`).
- An active `SeasonConfig.current_season_id` exists. Without it, `ContestsController#enter` aborts (`app/controllers/contests_controller.rb:295-297`).

## Sequence

### 1. Admin logs in via Phantom (SIWS)

1. **Click "Connect Wallet"** — `app/views/layouts/application.html.erb:100-147` (inline `solanaWalletConnect()` factory; must be inline because Alpine's `defer` evaluates `x-data` before importmap modules load).
2. **`GET /auth/solana/nonce`** — `app/controllers/solana_sessions_controller.rb:5-9`. Stores `session[:solana_nonce]` + `session[:solana_nonce_at]`.
   - Route: `config/routes.rb:84`.
3. **Client builds the SIWS message** and calls `provider.signMessage(...)` — `app/views/layouts/application.html.erb:117-124`.
   - Message format: `"<host> wants you to sign in with your Solana account:\n<pubkey>\n\nSign in to Turf Monster\n\nNonce: <nonce>"`. The opening `<host>` token is the OPSEC-018 host binding the server later asserts.
4. **`POST /auth/solana/verify`** — `app/controllers/solana_sessions_controller.rb:25-59`.
   - `verify_solana_signature!` (`app/controllers/concerns/solana/session_auth.rb:20-47`) deletes the nonce before verifying (replay protection) and delegates to `Solana::AuthVerifier.verify!` in the solana-studio gem with `expected_host: request.host_with_port`.
   - Looks up the user by wallet via `User.from_solana_wallet(pubkey_b58)` (`app/models/user.rb:87-89`); creates a new `User` if none exists.
   - `set_app_session(user)` (`app/controllers/application_controller.rb:19-28`) writes the session-token cookie and explicitly **clears** any stale `session[:onchain]` flag, then `session[:onchain] = true` is re-granted because this auth path is a genuine Phantom signature.
5. **Admin gate** — every admin route runs `before_action :require_admin` (`app/controllers/contests_controller.rb:6`). The helper is `Studio::ErrorHandling#require_admin` in `studio-engine`, which redirects with "Not authorized" unless `logged_in? && current_user.admin?`.

### 2. Initialize on-chain accounts — **conditional**

The `if needed` branch in the user's mental model maps to three distinct chain-init paths. Only the first is rare; the other two run silently on demand.

#### 2a. One-time vault init (rare — once per program ID)

Surfaced in the navbar admin dropdown as **"Vault Init"** with a yellow `!` badge:

- Visibility check: `Admin::VaultInitController.vault_uninitialized?` (`app/controllers/admin/vault_init_controller.rb:76-82`) — calls `Solana::Vault#read_vault_state` (`app/services/solana/vault.rb:250-285`) and caches the boolean for 1 hour. Bust on successful confirm.
- Dropdown link: `app/views/components/_admin_dropdown.html.erb:52-56`. Otherwise the link is "Vault State" (`app/views/components/_admin_dropdown.html.erb:58-63`).
- Routes: `config/routes.rb:235-237` — `GET admin/vault_init`, `POST admin/vault_init/build`, `POST admin/vault_init/confirm`.
- Flow:
  1. `Admin::VaultInitController#build` (`app/controllers/admin/vault_init_controller.rb:26-46`) validates params (`validate_init_params!` lines 90-110 — three distinct signers, threshold 1-3, creator must equal `INIT_AUTHORITY` on mainnet) and calls `Solana::Vault#build_initialize_vault` (`app/services/solana/vault.rb:217-245`). Bot fee-pays; the creator slot is left for Phantom.
  2. Phantom cosigns + broadcasts client-side.
  3. `Admin::VaultInitController#confirm` (`app/controllers/admin/vault_init_controller.rb:48-72`) verifies the TX via `Solana::TxVerifier.verify!` against the `initialize` discriminator + the vault PDA as writable + the creator as signer, then busts the `uninitialized?` cache.
- **Today's reality:** live devnet/mainnet program identity is canonical in `/Users/alex/projects/turf-vault/docs/CURRENT_DEPLOYMENT.md`. The admin will not see Vault Init on an already-initialized program; this branch only fires the first time the app points at a fresh program ID.

#### 2b. Per-season seed-schedule init (rare — once per Season)

`ContestsController#enter` (`app/controllers/contests_controller.rb:295-297`) raises **"No active season configured. Set one at /admin/seasons before users can enter on-chain contests."** when `SeasonConfig.current_season_id.to_i.zero?`. Step 4 will fail loudly if step 2b was skipped.

- Admin UI: `Admin::SeasonsController#create` (`app/controllers/admin/seasons_controller.rb:11-39`) reads `name`, `season_id`, and `slot_0..slot_4` from the form, calls `Solana::Vault#create_season(season_id:, name:, schedule:)`, and (when `params[:set_current] == "1"`) flips `SeasonConfig.set_current!(season_id)`.
- Routes: `config/routes.rb:248-250`.
- The on-chain `Season` PDA lives at `[b"season", season_id_le]` and stores the `seed_schedule` (default `[25, 19, 14, 10, 7]`) the `enter_contest` instruction reads to award seeds (see `docs/SOLANA.md`).

#### 2c. Per-contest Contest PDA init — **fires every time** in step 3

The contest PDA at `[b"contest", sha256(slug)]` is created by the `create_contest` instruction in step 3 below. There is no separate "init contract" click for this.

#### 2d. Per-user UserAccount PDA — fires lazily on first entry

`Solana::Vault#ensure_user_account` (`app/services/solana/vault.rb:383-393`) is called inline by every entry path (step 4 — `app/controllers/contests_controller.rb:434`). It checks the PDA size and either no-ops (`:ok`), creates the PDA via `create_user_account` (`app/services/solana/vault.rb:397-419`), or raises on schema drift (`:needs_migration`). For most admins this is a no-op because the after-create hook on `User` enqueues `CreateOnchainUserAccountJob` at signup (`docs/AUTH.md:48-54`).

### 3. Admin creates a contest

Phantom-driven, three-step. The DB row is only created **after** the on-chain TX confirms — no orphans possible.

1. **`GET /contests/new`** — `app/controllers/contests_controller.rb:24-35`. Form lives at `app/views/contests/new.html.erb:13-182`. Fields: `name`, `slate_id`, `contest_type` (one of `Contest.selectable_formats` — `app/models/contest.rb:117-119`; respects the `ENABLE_TEST_SCAFFOLDING` flag), `starts_at` / `locks_at_*`, `contest_image`. `entry_fee_cents` + `max_entries` are server-side derived from `format_config` (`app/models/contest.rb:121-123`, `app/controllers/contests_controller.rb:811-818`).
2. **Submit → `POST /contests`** — `ContestsController#create` (`app/controllers/contests_controller.rb:70-98`):
   - Refuses non-Phantom callers (`app/controllers/contests_controller.rb:71`).
   - `onchain_create_precheck` (`app/controllers/contests_controller.rb:841-857`) — slug uniqueness in DB; on-chain Contest PDA must not exist; `insufficient_usdc_error` (`app/controllers/contests_controller.rb:859-873`) verifies the creator's ATA balance covers `guaranteed_prize_cents`.
   - `Solana::Vault#build_create_contest` (`app/services/solana/vault.rb:548-586`) builds a partially-signed `create_contest` TX — admin signs as payer, creator (admin's Phantom) signs the USDC transfer. Account layout (`app/services/solana/vault.rb:570-580`): payer, creator, vault_state, contest (init), USDC mint, creator_ata, vault_usdc, token program, system program.
   - Server returns `{ serialized_tx, contest_pda, slug, params_token }`. The `params_token` is a `Rails.application.message_verifier` blob with 10-minute TTL (`app/controllers/contests_controller.rb:67-68`, `app/controllers/contests_controller.rb:878-895`) so the server can trust the re-posted form fields in step 3c without re-validating them.
3. **Phantom cosign + broadcast** — `app/views/contests/new.html.erb:300-309`. Client deserializes via `solanaWeb3.Transaction.from`, `provider.signTransaction`, `connection.sendRawTransaction`, then `connection.confirmTransaction(txSig, 'confirmed')`.
4. **`POST /contests/finalize`** — `ContestsController#finalize` (`app/controllers/contests_controller.rb:100-127`). Collection route (no `:id`) defined at `config/routes.rb:146`.
   - `verify_onchain_create_payload` (`app/controllers/contests_controller.rb:897-901`) decodes the `params_token`.
   - Re-derives `contest_pda` from `Solana::Vault#contest_pda(slug)` and demands `params[:contest_pda]` matches (`app/controllers/contests_controller.rb:104-105`).
   - `verify_solana_transaction!` (`app/controllers/contests_controller.rb:915-924`) → `Solana::TxVerifier.verify!` (OPSEC-010) — asserts the on-chain TX is the `create_contest` instruction signed by `creator_pubkey` writing to the derived PDA.
   - `build_finalized_contest` (`app/controllers/contests_controller.rb:820-836`) constructs the DB row with `skip_onchain_callback = true` (so the legacy `Contest#create_onchain!` `after_create` hook doesn't fire and double-spend — `app/models/contest.rb:39-40`, `app/models/contest.rb:156-158`). `before_create` binds `season_id` to `SeasonConfig.current_season_id` (`app/models/contest.rb:42-45`).
   - Attaches `contest_image` if present, then `contest.save!` returns `{ success: true, redirect: contest_path(contest), slug: }`.

> **Fallback path — server-funded.** `Contest#create_onchain!` (`app/models/contest.rb:136-154`) wired via `after_create :create_onchain_with_rollback!` (`app/models/contest.rb:40, 163-169`) calls `Solana::Vault#create_contest_server_funded` (`app/services/solana/vault.rb:599+`). Admin signs as both payer and creator, with prize-pool USDC funded from the configured server/admin wallet. Used for Rails console / scripts; auto-skipped in tests (`Rails.env.test?` in `skip_onchain_callback_active?`). The UI does not use this path.

### 4. Admin enters their own contest

Admins follow the **same** path as any other Phantom-authenticated user — there is no admin-only shortcut. The `comped: true` escape hatch (`app/models/entry.rb:59-100`) is **only** used by `Contest#fill!` (`app/models/contest.rb:286-292`) for bot-seeded test entries, not by a real admin entering through the UI.

Two-stage hold-to-confirm followed by the Phantom direct-entry signing flow:

1. **Toggle 6 selections** on the matchup board — `POST /contests/:id/toggle_selection` per click (`app/controllers/contests_controller.rb:652-673`). Each call `find_or_create_by!` the cart entry and toggles a `Selection` row. World Cup Survivor contests skip this step (`app/controllers/contests_controller.rb:265`).
2. **Hold-to-confirm** triggers the JS in `app/views/contests/_turf_totals_board.html.erb:899-996` (`confirmEntry()`):
   - Branches on `sess.isWeb3 && this.contestOnchain` (`app/views/contests/_turf_totals_board.html.erb:908`). Admin = web3 = always takes this branch.
3. **`POST /contests/:id/prepare_entry`** — `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:398-471`):
   - Requires `onchain_session?` (`app/controllers/contests_controller.rb:412`) — admin's Phantom-auth session has it set in step 1.
   - Validates exactly `picks_required` (= 6 for Turf Totals — `app/models/contest.rb:57-59`) selections and that none of the underlying games are `locked?` (`app/controllers/contests_controller.rb:422-425`).
   - Assigns `entry.entry_number` based on existing entries for this user/contest (`app/controllers/contests_controller.rb:428-429`).
   - `Solana::Vault#ensure_user_account(current_user.web3_solana_address)` — see 2d above.
   - `Solana::Vault#build_enter_contest(wallet, slug, entry_num, currency_idx:, season_id:)` builds the unified `enter_contest` transaction. Phantom-first flow leaves both admin and user signatures empty, then `confirm_onchain_entry` validates the user-signed wire before the server cosigns and broadcasts.
   - Persists a `PendingTransaction` with `tx_type: "enter_contest"`, `status: "pending"`, polymorphic `target: entry`, so a mid-flight refresh leaves a recoverable trail.
   - Returns `{ serialized_tx, entry_id, entry_pda, ptx_slug }`.
4. **Phantom signs, server broadcasts** — the browser signs the prepared wire transaction and posts it to `confirm_onchain_entry`; the server validates the signed wire, cosigns with the admin key, simulates, broadcasts, stamps the `PendingTransaction`, and verifies the resulting signature.
5. **`POST /contests/:id/confirm_onchain_entry`** — `ContestsController#confirm_onchain_entry`:
   - Re-derives `entry_pda` via `Solana::Vault#entry_pda(slug, wallet, entry_number)`; rejects mismatched client-supplied PDAs (`app/controllers/contests_controller.rb:579-582`).
   - `verify_solana_transaction!` asserts the TX is `enter_contest` signed by the user's wallet, cosigned by the admin server key, and writing to the derived entry PDA (OPSEC-010).
   - `Entry#confirm_onchain!` (`app/models/entry.rb:130+`) promotes the entry to `active`, stamps `onchain_tx_signature` + `onchain_entry_id`. The `comped:` flag is NOT passed — the on-chain TX itself is the payment proof (`app/models/entry.rb:97`).
   - Marks the PT `confirmed`, returns `{ success: true, redirect, tx_signature, seeds_earned, seeds_total, seeds_level }`.

## Data touched

- **DB:**
  - `users` (read — `from_solana_wallet`; insert if first login for this pubkey)
  - `season_configs` (read — `SeasonConfig.current_season_id`)
  - `contests` (insert — finalize step; updates `onchain_contest_id`, `onchain_tx_signature`)
  - `entries` (insert via `toggle_selection`; update to `active` via `confirm_onchain!`)
  - `selections` (insert per matchup toggle)
  - `pending_transactions` (insert in `prepare_entry`; update `tx_signature` + `status` through the lifecycle)
  - `transaction_logs` (read-only audit row at `confirm!` time when entry fee > 0 — `app/models/entry.rb:101-103`)
  - `outbound_requests` (insert per Solana RPC call via `Solana::ClientLogger`)
- **On-chain (turf-vault):**
  - `VaultState` PDA at `[b"vault"]` (read; **init** if 2a fires)
  - `Season` PDA at `[b"season", season_id_le]` (read; **init** if 2b fires)
  - `UserAccount` PDA at `[b"user", wallet]` (read; **init** if 2d fires — `ensure_user_account`)
  - `Contest` PDA at `[b"contest", sha256(slug)]` (**init** via `create_contest` IX in step 3)
  - `ContestEntry` PDA at `[b"entry", contest_pda, wallet, entry_num_le]` (**init** via `enter_contest` IX in step 4)
  - SPL token transfers: creator ATA → per-contest prize-pool ATA for the prize pool (step 3); user ATA → per-currency operator-revenue ATA for the entry fee (step 4)
- **External:** Solana RPC (every `build_*` re-derives PDAs; server-signed paths use `client.send_and_confirm`; Phantom entry signs in-browser and broadcasts server-side after admin cosign).

## Failure modes

- **Wrong wallet connected** — `app/views/contests/new.html.erb:281-283` (creation) and `app/views/contests/_turf_totals_board.html.erb:923-925` (entry) throw client-side before signing. User-visible: error modal "Switch to <pubkey>… in Phantom".
- **Insufficient USDC for prize pool** — `onchain_create_precheck` (`app/controllers/contests_controller.rb:856`) returns the error string; client modal offers a "Mint $500 Test USDC" recovery button hitting `POST /faucet` (`app/views/contests/new.html.erb:227-251`). Production-disabled per OPSEC-020 (`app/controllers/admin_controller.rb:189`).
- **On-chain Contest PDA already exists** — `onchain_create_precheck` line 848-854. Common after a finalize that confirmed on-chain but failed at `verify_solana_transaction!` or `save!`. Admin must pick a different name (slug-derived) or operate manually on the stranded PDA.
- **No active season** — `app/controllers/contests_controller.rb:295-297` raises in `#enter`. User-visible alert: "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." → admin loops back to 2b.
- **Sign-then-refresh during entry** — `PendingTransaction` left as `pending` or `submitted`. The board JS polls `POST /contests/:id/recover_pending_entry` (`app/controllers/contests_controller.rb:502-565`) which either promotes the entry (`status == confirmed`/`finalized`), keeps polling (`processing`), or fails-and-releases (`failed`).
- **IDL hash drift after a turf-vault upgrade** — `Solana::Config#verify_idl!` refuses to boot in production (`docs/SOLANA.md:54-55`). Borsh decoding would silently corrupt every account read otherwise. Operator must re-pin `EXPECTED_IDL_HASH` from the freshly **built** IDL (NOT `anchor idl fetch`) before pushing. See `feedback_post_deploy_idl_pin` memory.
- **Session token mismatch** — `ApplicationController#verify_session_token` (`app/controllers/application_controller.rb:60-74`) force-logs-out a stale session (OPSEC-045). Admin re-runs step 1.
- **Tx fails `Solana::TxVerifier`** — controller rescues `VerificationError` and surfaces the message via JSON `{ error }`; the finalize / confirm endpoint returns 422 without creating the DB row. The on-chain side may already be committed — operator inspects via `/admin/outbound_requests` + Solana explorer.

## Related workflows

- [[web3-landing-to-entry]] — same Phantom auth + Phantom direct-entry signing path, just from a non-admin user landing on `/l/:slug` instead of `/contests/new`. Steps 1 and 4 above are shared.
- [[email-signup-token-to-chat]] — managed-wallet alternative entry path: `ContestsController#enter` falls through to the `enter_contest_with_token` branch (`app/controllers/contests_controller.rb:311-335`) which consumes an `EntryTokenAccount` PDA instead of charging USDC. Admin never hits this branch.
- [[referral-google-tokens-to-chat]] — Google OAuth signup path; lands the user in the same `enter` action with a managed wallet, taking the token-consume branch.
